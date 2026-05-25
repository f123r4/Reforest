// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {AgentAccessControl} from "../shared/AgentAccessControl.sol";

/**
 * @title ProBonoRegistry — ProBono Ledger
 * @notice Currículo on-chain de horas pro-bono validadas, em SBTs.
 *
 * @dev Cada hora pro-bono validada por um advogado vira UM SBT (Soulbound Token)
 *      na carteira dele. Intransferível. Acumula como reputação verificável.
 *
 *      Decisão de modelagem (SBT via ERC-721):
 *      - Herdamos ERC-721 e SOBREESCREVEMOS `_update` para reverter qualquer
 *        transferência de um token já mintado (mas permitimos mint inicial).
 *      - Isso é o padrão EIP-5114 em espírito (não na letra) — produz NFTs
 *        que indexadores como OpenSea já entendem (= ótimo UX), mas que NÃO
 *        podem mudar de mão (= reputação pessoal e não-revendível).
 *
 *      Defesa contra inflar horas:
 *      - O validator mint sob `(lawyer, caseId, hoursIndex)`. Se já existe SBT
 *        para essa tripla, reverte. Hours são "blocos de 1 hora cada"; o validator
 *        confere via DJE que o advogado de fato atuou no caso.
 *
 *      Ranking on-chain:
 *      - `totalHoursOf[address]`: contagem cumulativa por advogado
 *      - `hoursByOdsOf[address][ods]`: por ODS (Objetivos de Desenvolvimento Sustentável)
 *      - Front-end faz queries simples e gera rankings sem precisar de event scan.
 */
contract ProBonoRegistry is ERC721, AgentAccessControl {
    /// @notice Worker que cruza horas declaradas vs DJE e mintar SBTs validados.
    bytes32 public constant DJE_VALIDATOR_ROLE = keccak256("PROBONO_DJE_VALIDATOR_ROLE");

    /// @dev ODS = Objetivos de Desenvolvimento Sustentável (ONU). 1..17.
    ///      Usamos uint8 — só temos 17 ODS, e 255 cabe folgado para extensões.
    struct HourCertificate {
        address lawyer;
        bytes32 caseRef;            // identificador único do caso (hash do CNJ + escritório)
        uint8 ods;                   // 1..17
        uint8 legalArea;             // espelha FeeSplitter.LegalArea — convenção compartilhada
        uint16 hourIndex;            // 1ª, 2ª, ... N-ésima hora daquele caso
        uint64 validatedAt;
        string dejProofId;          // referência da publicação do DJE que provou
    }

    mapping(uint256 => HourCertificate) public certificateOf;
    mapping(address => uint256) public totalHoursOf;
    mapping(address => mapping(uint8 => uint256)) public hoursByOdsOf;

    /// @dev Defesa anti-dupla-validação: chave = keccak256(lawyer, caseRef, hourIndex).
    mapping(bytes32 => bool) internal _claimed;

    uint256 public nextTokenId = 1;

    event HourValidated(
        uint256 indexed tokenId,
        address indexed lawyer,
        bytes32 indexed caseRef,
        uint8 ods,
        uint16 hourIndex,
        address validator,
        string dejProofId
    );

    constructor(address initialAdmin)
        ERC721("ProBono Hours Ledger", "PROBONO")
        AgentAccessControl(initialAdmin)
    {
        _setRoleAdmin(DJE_VALIDATOR_ROLE, ADMIN_ROLE);
    }

    /**
     * @notice Mintar 1 SBT representando 1 hora validada.
     * @dev Idempotência: tentar re-mintar (mesmo lawyer + caseRef + hourIndex) reverte.
     *      Validator deve incrementar hourIndex a cada hora nova.
     */
    function validateHour(
        address lawyer,
        bytes32 caseRef,
        uint8 ods,
        uint8 legalArea,
        uint16 hourIndex,
        string calldata dejProofId
    ) external onlyRole(DJE_VALIDATOR_ROLE) returns (uint256 tokenId) {
        require(lawyer != address(0), "Advogado invalido");
        require(ods >= 1 && ods <= 17, "ODS deve estar em 1..17");
        require(hourIndex > 0, "hourIndex deve ser > 0");
        require(bytes(dejProofId).length > 0, "Prova DJE obrigatoria");

        bytes32 claimKey = keccak256(abi.encodePacked(lawyer, caseRef, hourIndex));
        require(!_claimed[claimKey], "Hora ja validada");
        _claimed[claimKey] = true;

        tokenId = nextTokenId++;
        certificateOf[tokenId] = HourCertificate({
            lawyer: lawyer,
            caseRef: caseRef,
            ods: ods,
            legalArea: legalArea,
            hourIndex: hourIndex,
            validatedAt: uint64(block.timestamp),
            dejProofId: dejProofId
        });

        totalHoursOf[lawyer] += 1;
        hoursByOdsOf[lawyer][ods] += 1;

        _safeMint(lawyer, tokenId);
        emit HourValidated(tokenId, lawyer, caseRef, ods, hourIndex, msg.sender, dejProofId);
    }

    /**
     * @notice Bloqueia transferências. Permite apenas mint (from = 0) e burn (to = 0).
     * @dev OZ ERC-721 v5 unifica mint/transfer/burn em `_update`. Para soulbound,
     *      basta interceptar transfers reais e reverter. Burn intencionalmente fica
     *      permitido: o titular pode "renunciar" ao certificado se quiser (raro mas
     *      possível em casos de erro ou anulação).
     */
    function _update(address to, uint256 tokenId, address auth)
        internal
        override
        returns (address)
    {
        address from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0)) {
            revert("SBT: nao transferivel");
        }
        // Se for burn (to = 0), também atualizamos contadores para consistência.
        if (to == address(0) && from != address(0)) {
            HourCertificate memory c = certificateOf[tokenId];
            totalHoursOf[from] -= 1;
            hoursByOdsOf[from][c.ods] -= 1;
        }
        return super._update(to, tokenId, auth);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
