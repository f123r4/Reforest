// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {AgentAccessControl} from "../shared/AgentAccessControl.sol";
import {TreeNFT} from "./TreeNFT.sol";

/**
 * @title ReforestVault
 * @notice Cofre de doações com liberação travada por milestones de sobrevivência.
 *
 * Doadores depositam USDC. O oracle satelital reporta survival rate a cada
 * milestone (M0/M6/M12/M36). Se >= 75%, libera a fatia do plantador.
 * Se reprovar, o valor fica disponível pra refund proporcional aos doadores.
 *
 * TODO: em prod trocar EOA do admin por multisig
 */
contract ReforestVault is AgentAccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant GEO_ORACLE_ROLE = keccak256("REFOREST_GEO_ORACLE_ROLE");

    // delays a partir do plantio
    uint64 public constant M0_DELAY = 0;
    uint64 public constant M6_DELAY = 180 days;
    uint64 public constant M12_DELAY = 365 days;
    uint64 public constant M36_DELAY = 3 * 365 days;

    // % liberado por milestone em bps (soma = 10000)
    uint16 public constant M0_BPS = 1_000;
    uint16 public constant M6_BPS = 3_000;
    uint16 public constant M12_BPS = 3_000;
    uint16 public constant M36_BPS = 3_000;
    uint16 public constant BPS_DIVISOR = 10_000;

    uint16 public constant SURVIVAL_THRESHOLD_BPS = 7_500; // 75%

    enum Milestone { M0, M6, M12, M36 }
    enum MilestoneStatus { PENDING, APPROVED, REJECTED }

    struct Project {
        address planter;
        bytes32 geoHash;
        string species;
        int256 gpsLatE6;
        int256 gpsLngE6;
        uint32 plannedTrees;
        uint128 budgetTotal;       // USDC total alvo
        uint128 budgetRaised;      // já doado
        uint128 budgetReleased;    // já pago ao plantador
        uint64 plantedAt;           // 0 se ainda não plantado
        bool exists;
    }

    mapping(uint256 => Project) public projects;
    mapping(uint256 => mapping(uint8 => MilestoneStatus)) public milestoneStatus;
    mapping(uint256 => mapping(address => uint128)) public donatedBy; // pra calcular refund proporcional

    uint256 public nextProjectId = 1;

    IERC20 public immutable paymentToken;
    TreeNFT public immutable treeNft;

    // ============================ Events ============================

    event ProjectCreated(
        uint256 indexed projectId,
        address indexed planter,
        uint32 plannedTrees,
        uint128 budgetTotal
    );
    event Donated(
        uint256 indexed projectId,
        address indexed donor,
        uint128 amount,
        bool nftMinted,
        uint256 nftTokenId
    );
    event Planted(uint256 indexed projectId, uint64 plantedAt);
    event MilestoneReported(
        uint256 indexed projectId,
        Milestone milestone,
        uint16 survivalBps,
        bool approved,
        address indexed reporter,
        bytes32 dataSourceHash
    );
    event PayoutReleased(uint256 indexed projectId, Milestone milestone, uint128 amount);
    event Refunded(uint256 indexed projectId, address indexed donor, uint128 amount);

    constructor(address admin, IERC20 paymentToken_, TreeNFT treeNft_)
        AgentAccessControl(admin)
    {
        paymentToken = paymentToken_;
        treeNft = treeNft_;
        _setRoleAdmin(GEO_ORACLE_ROLE, ADMIN_ROLE);
    }

    // ============================ Project lifecycle ============================

    function createProject(
        address planter,
        bytes32 geoHash,
        string calldata species,
        int256 gpsLatE6,
        int256 gpsLngE6,
        uint32 plannedTrees,
        uint128 budgetTotal
    ) external onlyRole(ADMIN_ROLE) returns (uint256 projectId) {
        require(planter != address(0), "Planter invalido");
        require(plannedTrees > 0 && budgetTotal > 0, "Parametros invalidos");
        require(geoHash != bytes32(0), "GeoHash invalido");

        projectId = nextProjectId++;
        projects[projectId] = Project({
            planter: planter,
            geoHash: geoHash,
            species: species,
            gpsLatE6: gpsLatE6,
            gpsLngE6: gpsLngE6,
            plannedTrees: plannedTrees,
            budgetTotal: budgetTotal,
            budgetRaised: 0,
            budgetReleased: 0,
            plantedAt: 0,
            exists: true
        });
        emit ProjectCreated(projectId, planter, plannedTrees, budgetTotal);
    }

    /**
     * @notice Doador deposita USDC. Opcionalmente minta TreeNFT como certificado.
     * @dev Ao mintar NFT, USAMOS o mesmo evento Donated com nftTokenId > 0 — fonte
     *      única de verdade. Reduz acoplamento entre NFT e Vault no lado do indexer.
     */
    function donate(uint256 projectId, uint128 amount, bool mintNft) external nonReentrant {
        Project storage p = projects[projectId];
        require(p.exists, "Projeto inexistente");
        require(amount > 0, "Valor invalido");
        require(p.budgetRaised + amount <= p.budgetTotal, "Excede orcamento");

        paymentToken.safeTransferFrom(msg.sender, address(this), amount);
        p.budgetRaised += amount;
        donatedBy[projectId][msg.sender] += amount;

        uint256 nftTokenId = 0;
        if (mintNft) {
            nftTokenId = treeNft.mintTree(
                msg.sender, projectId, p.species, p.gpsLatE6, p.gpsLngE6
            );
        }
        emit Donated(projectId, msg.sender, amount, mintNft, nftTokenId);
    }

    /**
     * @notice Plantador declara que executou o plantio. Marca timestamp para os milestones.
     * @dev Sem essa chamada, M0..M36 não progridem. Defesa contra projeto "fantasma"
     *      que recebeu doação mas nunca foi a campo.
     */
    function declarePlanted(uint256 projectId) external {
        Project storage p = projects[projectId];
        require(p.exists, "Projeto inexistente");
        require(msg.sender == p.planter, "Apenas plantador");
        require(p.plantedAt == 0, "Plantio ja declarado");
        p.plantedAt = uint64(block.timestamp);
        emit Planted(projectId, uint64(block.timestamp));
    }

    // ============================ Oracle milestones ============================

    /**
     * @notice Oracle reporta survival rate de um milestone. Se >= threshold → aprovado e payout.
     * @param survivalBps Survival rate em basis points (ex: 8000 = 80%).
     * @param dataSourceHash SHA-256 do identificador da cena satelital usada (ex: hash do
     *        Sentinel-2 scene ID + data), permitindo que qualquer auditor re-derive o índice
     *        NDVI a partir de dados públicos da ESA e verifique o valor reportado.
     * @dev O oracle só pode reportar um milestone QUE ESTÁ DENTRO DO PRAZO previsto
     *      (ex: M6 só após 180 dias do plantio). Isso impede aprovação prematura, ex:
     *      reportar M36 logo após o plantio.
     */
    function reportMilestone(
        uint256 projectId,
        Milestone milestone,
        uint16 survivalBps,
        bytes32 dataSourceHash
    ) external onlyRole(GEO_ORACLE_ROLE) nonReentrant {
        Project storage p = projects[projectId];
        require(p.exists, "Projeto inexistente");
        require(p.plantedAt > 0, "Plantio nao declarado");
        require(survivalBps <= BPS_DIVISOR, "Survival invalido");

        uint8 mi = uint8(milestone);
        require(milestoneStatus[projectId][mi] == MilestoneStatus.PENDING, "Milestone ja reportado");

        // Janela temporal — oracle não pode "pular" antecipando milestone.
        uint64 minTimestamp = p.plantedAt + _milestoneDelay(milestone);
        require(block.timestamp >= minTimestamp, "Milestone fora do prazo");

        bool approved = survivalBps >= SURVIVAL_THRESHOLD_BPS;
        milestoneStatus[projectId][mi] = approved ? MilestoneStatus.APPROVED : MilestoneStatus.REJECTED;

        emit MilestoneReported(projectId, milestone, survivalBps, approved, msg.sender, dataSourceHash);

        if (approved) {
            uint16 bps = _milestoneBps(milestone);
            // Payout = bps% do total ARRECADADO (não do total alvo — projeto pode estar
            // sub-financiado e o oracle não força o plantador a esperar 100% do alvo).
            uint128 payout = uint128((uint256(p.budgetRaised) * bps) / BPS_DIVISOR);
            p.budgetReleased += payout;
            paymentToken.safeTransfer(p.planter, payout);
            emit PayoutReleased(projectId, milestone, payout);
        }
    }

    // ============================ Refunds ============================

    /**
     * @notice Doador resgata pro-rata da parte que NÃO foi liberada por milestones reprovados.
     * @dev Lógica: o doador pode resgatar SUA fatia da diferença entre arrecadado e
     *      released, MAS apenas após o último milestone (M36) ter sido decidido.
     *      Antes disso, ainda há chance de futuros milestones aprovarem e liberarem mais.
     *
     *      Pro-rata = (doação do user / total arrecadado) * (arrecadado - released).
     */
    function refund(uint256 projectId) external nonReentrant {
        Project storage p = projects[projectId];
        require(p.exists, "Projeto inexistente");
        // M36 precisa estar resolvido (aprovado OU reprovado), não pendente.
        require(
            milestoneStatus[projectId][uint8(Milestone.M36)] != MilestoneStatus.PENDING,
            "Aguardar resolucao do milestone final"
        );

        uint128 userDonation = donatedBy[projectId][msg.sender];
        require(userDonation > 0, "Sem direito a reembolso");

        uint128 totalUndistributed = p.budgetRaised - p.budgetReleased;
        uint128 share = uint128((uint256(userDonation) * totalUndistributed) / p.budgetRaised);
        // Zera ANTES de transferir (CEI pattern, defesa contra reentrância se token for hostil).
        donatedBy[projectId][msg.sender] = 0;

        if (share > 0) {
            paymentToken.safeTransfer(msg.sender, share);
            emit Refunded(projectId, msg.sender, share);
        }
    }

    // ============================ Views ============================

    function isMilestoneReady(uint256 projectId, Milestone milestone) external view returns (bool) {
        Project memory p = projects[projectId];
        if (!p.exists || p.plantedAt == 0) return false;
        return block.timestamp >= p.plantedAt + _milestoneDelay(milestone);
    }

    // ============================ Internal ============================

    function _milestoneDelay(Milestone m) internal pure returns (uint64) {
        if (m == Milestone.M0) return M0_DELAY;
        if (m == Milestone.M6) return M6_DELAY;
        if (m == Milestone.M12) return M12_DELAY;
        return M36_DELAY;
    }

    function _milestoneBps(Milestone m) internal pure returns (uint16) {
        if (m == Milestone.M0) return M0_BPS;
        if (m == Milestone.M6) return M6_BPS;
        if (m == Milestone.M12) return M12_BPS;
        return M36_BPS;
    }
}
