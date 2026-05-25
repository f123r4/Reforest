// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {AgentAccessControl} from "../shared/AgentAccessControl.sol";

/**
 * @title DonorDAOTreasury — DonorDAO
 * @notice Cofre comunitário de doação com alocação por proposta votada on-chain.
 *
 * @dev Mecânica:
 *      - Doadores depositam USDC; recebem voting power proporcional à contribuição.
 *      - ONGs cadastradas (NGO_ROLE) submetem propostas (título, hash dos detalhes,
 *        valor solicitado).
 *      - Doadores votam yes/no na janela de votação (7 dias).
 *      - Após o fim da janela, qualquer um chama `execute`:
 *          - se quorum atingido E maioria sim → transfere USDC para a ONG.
 *          - senão, marca como rejeitada (sem transferência).
 *      - Doador retira o que sobrou DESDE QUE não tenha voto em proposta pendente.
 *
 *      Por que voting power = contribuição (não 1-pessoa-1-voto):
 *      - Sem KYC on-chain, 1p1v é trivialmente sybilizável. Skin-in-the-game é a
 *        única defesa pragmática para MVP.
 *      - Em V2, mistura com SBT de reputação (ProBono / VoluntChain) → quadrático.
 *
 *      Defesa contra "vote-then-withdraw":
 *      - Voto é registrado com peso = `contributed` no momento do voto.
 *      - Doador NÃO pode withdraw enquanto tiver voto em proposta PENDING — o
 *        contador `openVoteCount[voter]` impede.
 *      - Ao `execute`, o contrato decrementa o contador de todos os voters daquela
 *        proposta (lista armazenada). Quando o contador zera, withdraw destrava.
 *
 *      Defesa de re-entrada:
 *      - `execute` usa CEI + ReentrancyGuard; status mudado ANTES da transfer.
 */
contract DonorDAOTreasury is AgentAccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant NGO_ROLE = keccak256("DONORDAO_NGO_ROLE");

    uint64 public constant VOTING_PERIOD = 7 days;
    uint16 public constant QUORUM_BPS = 3_000;     // 30% do voting power
    uint16 public constant APPROVAL_BPS = 6_000;   // 60% yes entre votos validos
    uint16 public constant BPS_DIVISOR = 10_000;

    IERC20 public immutable token;

    struct Member {
        uint128 contributed;        // total já depositado
        uint32 openVoteCount;       // votos em propostas ainda PENDING
    }

    enum ProposalStatus {PENDING, APPROVED, REJECTED}

    struct Proposal {
        address ngo;
        bytes32 detailsHash;        // hash IPFS / PDF descritivo
        string title;
        uint128 amount;             // USDC solicitado
        uint64 votingEnds;
        uint128 yesVotes;
        uint128 noVotes;
        ProposalStatus status;
        bool exists;
    }

    mapping(address => Member) public members;
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    /// @dev Lista de voters por proposta — precisamos varrer no execute para
    ///      destravar withdrawals. Custo: O(voters) por execute. Aceitável para
    ///      o cenário "comunidade local" (10..200 voters/proposta).
    mapping(uint256 => address[]) internal _voters;

    uint128 public totalContributed;
    uint128 public totalExecuted;

    uint256 public nextProposalId = 1;

    // ============================ Events ============================

    event Deposited(address indexed donor, uint128 amount, uint128 totalContributed);
    event Withdrawn(address indexed donor, uint128 amount);
    event ProposalSubmitted(
        uint256 indexed proposalId,
        address indexed ngo,
        uint128 amount,
        uint64 votingEnds,
        bytes32 detailsHash
    );
    event Voted(uint256 indexed proposalId, address indexed voter, bool support, uint128 weight);
    event ProposalExecuted(uint256 indexed proposalId, ProposalStatus status, uint128 transferred);

    constructor(address initialAdmin, IERC20 token_) AgentAccessControl(initialAdmin) {
        token = token_;
        _setRoleAdmin(NGO_ROLE, ADMIN_ROLE);
    }

    // ============================ Donor ============================

    function deposit(uint128 amount) external nonReentrant {
        require(amount > 0, "Valor zero");
        token.safeTransferFrom(msg.sender, address(this), amount);
        members[msg.sender].contributed += amount;
        totalContributed += amount;
        emit Deposited(msg.sender, amount, members[msg.sender].contributed);
    }

    function withdraw(uint128 amount) external nonReentrant {
        Member storage m = members[msg.sender];
        require(amount > 0 && amount <= m.contributed, "Excede contribuicao");
        require(m.openVoteCount == 0, "Voto pendente trava saldo");

        m.contributed -= amount;
        totalContributed -= amount;
        token.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    // ============================ Proposal lifecycle ============================

    function submitProposal(string calldata title, bytes32 detailsHash, uint128 amount)
        external
        onlyRole(NGO_ROLE)
        returns (uint256 proposalId)
    {
        require(amount > 0, "Valor invalido");
        require(detailsHash != bytes32(0), "Detalhes obrigatorios");
        require(bytes(title).length > 0 && bytes(title).length <= 80, "Titulo invalido");
        require(amount <= _availableBalance(), "Excede saldo da treasury");

        proposalId = nextProposalId++;
        uint64 deadline = uint64(block.timestamp + VOTING_PERIOD);
        proposals[proposalId] = Proposal({
            ngo: msg.sender,
            detailsHash: detailsHash,
            title: title,
            amount: amount,
            votingEnds: deadline,
            yesVotes: 0,
            noVotes: 0,
            status: ProposalStatus.PENDING,
            exists: true
        });
        emit ProposalSubmitted(proposalId, msg.sender, amount, deadline, detailsHash);
    }

    function vote(uint256 proposalId, bool support) external {
        Proposal storage p = proposals[proposalId];
        require(p.exists, "Proposta inexistente");
        require(p.status == ProposalStatus.PENDING, "Proposta encerrada");
        require(block.timestamp < p.votingEnds, "Votacao encerrada");
        require(!hasVoted[proposalId][msg.sender], "Ja votou");

        uint128 weight = members[msg.sender].contributed;
        require(weight > 0, "Sem voting power");

        hasVoted[proposalId][msg.sender] = true;
        _voters[proposalId].push(msg.sender);
        members[msg.sender].openVoteCount += 1;

        if (support) p.yesVotes += weight;
        else p.noVotes += weight;
        emit Voted(proposalId, msg.sender, support, weight);
    }

    /**
     * @notice Resolve a proposta após o fim da janela. Pode ser chamado por qualquer um.
     * @dev Destrava os voters (decrementa openVoteCount) — independente do resultado.
     */
    function execute(uint256 proposalId) external nonReentrant {
        Proposal storage p = proposals[proposalId];
        require(p.exists, "Proposta inexistente");
        require(p.status == ProposalStatus.PENDING, "Ja executada");
        require(block.timestamp >= p.votingEnds, "Votacao em andamento");

        uint128 totalVotes = p.yesVotes + p.noVotes;
        uint128 quorumNeeded = uint128((uint256(totalContributed) * QUORUM_BPS) / BPS_DIVISOR);
        bool quorumOk = totalVotes >= quorumNeeded;
        bool majorityYes = totalVotes > 0 &&
            (uint256(p.yesVotes) * BPS_DIVISOR) / totalVotes >= APPROVAL_BPS;

        uint128 transferred = 0;
        if (quorumOk && majorityYes) {
            require(p.amount <= _availableBalance(), "Treasury insuficiente");
            p.status = ProposalStatus.APPROVED;
            totalExecuted += p.amount;
            transferred = p.amount;
            token.safeTransfer(p.ngo, p.amount);
        } else {
            p.status = ProposalStatus.REJECTED;
        }

        // Destrava todos os voters desta proposta.
        address[] storage voters = _voters[proposalId];
        for (uint256 i = 0; i < voters.length; i++) {
            // Underflow é impossível: vote() só incrementa se o voter ainda não votou.
            members[voters[i]].openVoteCount -= 1;
        }

        emit ProposalExecuted(proposalId, p.status, transferred);
    }

    // ============================ Views ============================

    function availableBalance() external view returns (uint128) {
        return _availableBalance();
    }

    function quorumRequired() external view returns (uint128) {
        return uint128((uint256(totalContributed) * QUORUM_BPS) / BPS_DIVISOR);
    }

    function votersOf(uint256 proposalId) external view returns (address[] memory) {
        return _voters[proposalId];
    }

    // ============================ Internals ============================

    function _availableBalance() internal view returns (uint128) {
        return uint128(token.balanceOf(address(this)));
    }
}
