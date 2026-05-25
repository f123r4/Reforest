// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {AgentAccessControl} from "../shared/AgentAccessControl.sol";

/**
 * @title TreeNFT — ReForest+
 * @notice Certificado de impacto ambiental: cada NFT representa uma árvore (ou
 *         um pequeno grupo de árvores) plantada via ReforestVault.
 *
 * @dev Decisão de modelagem: é um ERC-721 padrão (não soulbound) porque o doador
 *      pode querer revender o certificado no futuro — exatamente como créditos de
 *      carbono modernos. A árvore segue plantada; o título do impacto pode trocar
 *      de mãos. Para um modelo SBT, o ProBono Ledger ilustra o oposto.
 *
 *      Os metadados ricos (GPS, espécie, projeto, milestone) ficam em storage
 *      on-chain — é caro em gas mas é a inovação central, e o volume baixo
 *      (centenas/milhares de NFTs por projeto) torna aceitável. Em escala
 *      milionária, migraríamos para metadata off-chain referenciada por IPFS.
 *
 *      Apenas o ReforestVault (vinculado por papel) pode mintar — evita
 *      certificados "fantasma" sem doação real por trás.
 */
contract TreeNFT is ERC721, AgentAccessControl {
    /// @notice Papel concedido ao ReforestVault para mintar quando um doador opta pelo NFT.
    bytes32 public constant MINTER_ROLE = keccak256("REFOREST_MINTER_ROLE");

    struct TreeMetadata {
        uint256 projectId;          // qual projeto financiou
        string species;              // ex: "Ipê-amarelo" (Handroanthus albus)
        int256 gpsLatE6;            // latitude * 1e6 (preserva 6 casas decimais)
        int256 gpsLngE6;            // longitude * 1e6
        uint64 plantedAt;            // timestamp do plantio
        address originalDonor;      // doador que mintou (pode mudar de owner depois)
    }

    mapping(uint256 => TreeMetadata) public metadata;

    uint256 public nextTokenId = 1;

    event TreeMinted(
        uint256 indexed tokenId,
        uint256 indexed projectId,
        address indexed donor,
        string species
    );

    constructor(address initialAdmin)
        ERC721("TreeNFT ReForest+", "TREE")
        AgentAccessControl(initialAdmin)
    {
        _setRoleAdmin(MINTER_ROLE, ADMIN_ROLE);
    }

    function mintTree(
        address donor,
        uint256 projectId,
        string calldata species,
        int256 gpsLatE6,
        int256 gpsLngE6
    ) external onlyRole(MINTER_ROLE) returns (uint256 tokenId) {
        tokenId = nextTokenId++;
        metadata[tokenId] = TreeMetadata({
            projectId: projectId,
            species: species,
            gpsLatE6: gpsLatE6,
            gpsLngE6: gpsLngE6,
            plantedAt: uint64(block.timestamp),
            originalDonor: donor
        });
        _safeMint(donor, tokenId);
        emit TreeMinted(tokenId, projectId, donor, species);
    }

    // ERC721 e AccessControl (via AgentAccessControl) ambos implementam supportsInterface.
    // O Solidity exige que listemos os contratos BASE diretos em `override(...)` — como
    // AgentAccessControl é abstract e herda de AccessControl, listamos AccessControl
    // como o nome canônico via cadeia de herança.
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
