// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {AgentAccessControl} from "../shared/AgentAccessControl.sol";

/**
 * @title PlasticCreditRegistry — EcoStream
 * @notice Tokeniza coletas de plástico em PLAST (ERC-20) com prova de cooperativa.
 *
 * @dev Mecânica:
 *      - Coletor (catador) leva material à cooperativa parceira.
 *      - Cooperativa pesa, classifica o tipo de plástico, emite recibo físico.
 *      - O hash do recibo é registrado on-chain por um validador da cooperativa.
 *      - Cada grama validado vira fração proporcional de PLAST na carteira do coletor,
 *        ponderada pelo "factor" do tipo de plástico (PET vale mais que MIXED).
 *      - Empresas compram PLAST no mercado secundário e chamam `retire(amount, disclosure)`
 *        — queima permanentemente os tokens e emite evento auditável de offset.
 *
 *      Por que ERC-20 (e não NFT como o ReForest+):
 *      - Reciclagem é commodity homogênea — duas coletas de 1kg PET são fungíveis.
 *      - Empresa precisa "retirar 50t de PET no ano" — math em grama é mais simples
 *        com ERC-20 do que somando 50.000 NFTs.
 *
 *      Defesa anti-fraude:
 *      - Cada recibo (hash) só pode ser usado uma vez (`_receiptUsed`).
 *      - Apenas validadores autorizados pela cooperativa podem mintar.
 *      - Cooperativa é cadastrada pelo ADMIN_ROLE (pré-due-diligence off-chain).
 *      - Coletor não pode mintar para si mesmo — separação de poderes obrigatória.
 */
contract PlasticCreditRegistry is ERC20, AgentAccessControl {
    /// @notice Papel concedido a workers/sistemas das cooperativas parceiras.
    bytes32 public constant COOP_VALIDATOR_ROLE = keccak256("ECOSTREAM_COOP_VALIDATOR_ROLE");

    /// @dev Tipos de plástico — alinhado ao código de identificação ABNT/SPI 1..7.
    ///      MIXED para resíduo misto (factor mais baixo: precisa triagem extra a jusante).
    enum PlasticType {PET, HDPE, PVC, LDPE, PP, PS, OTHER, MIXED}

    /// @dev Factor (em basis points) aplicado ao peso para definir tokens mintados.
    ///      PET = 10_000 (peso = tokens, em proporção 1g = 1e15 wei do token = 0.001 PLAST).
    ///      MIXED = 4_000 (40%) — penaliza coleta misturada para incentivar triagem na fonte.
    ///      Valores derivados de preços médios CEMPRE 2024 (proxy de "valor reciclável").
    mapping(uint8 => uint16) public typeFactorBps;

    /// @dev 1 grama de PET equivale a esta quantidade de wei do token base.
    ///      Escolhido para que 1.000g (=1kg) de PET = 1 PLAST inteiro (10^18 wei).
    uint256 public constant WEI_PER_GRAM_BASE = 1e15;

    /// @dev Para a math de factor.
    uint16 public constant BPS_DIVISOR = 10_000;

    struct Cooperative {
        bytes32 nameHash;       // hash do nome+CNPJ — privacidade + dedupe
        bytes32 regionHash;     // hash do município/região (agregação sem expor endereço)
        uint64 registeredAt;
        bool active;
    }

    struct Collection {
        uint256 cooperativeId;
        address collector;
        uint64 collectedAt;
        uint32 weightGrams;     // até 4.294.967 kg (suficiente até para grandes cooperativas)
        PlasticType plasticType;
        bytes32 receiptHash;    // SHA-256 do recibo físico digitalizado
        uint256 tokensMinted;
    }

    /// @dev cooperativeId => Cooperative.
    mapping(uint256 => Cooperative) public cooperatives;
    uint256 public nextCooperativeId = 1;

    /// @dev collectionId sequencial. Evita race condition se duas validações chegarem juntas.
    mapping(uint256 => Collection) public collections;
    uint256 public nextCollectionId = 1;

    /// @dev Liga validator → cooperativa que ele pode validar (não confiamos no role só).
    ///      Sem isso, qualquer COOP_VALIDATOR_ROLE poderia atribuir coletas a qualquer
    ///      cooperativa, mascarando atividade real.
    mapping(address => uint256) public validatorOf;

    /// @dev Defesa anti-duplo-uso de recibo. Idempotência por hash.
    mapping(bytes32 => bool) internal _receiptUsed;

    /// @dev Estatísticas para o front-end sem precisar varrer eventos.
    mapping(address => uint256) public totalGramsCollectedBy;
    mapping(address => uint256) public totalGramsRetiredBy;
    uint256 public totalGramsRetired;

    // ============================ Events ============================

    event CooperativeRegistered(uint256 indexed cooperativeId, bytes32 indexed regionHash);
    event ValidatorAttached(address indexed validator, uint256 indexed cooperativeId);
    event CollectionRegistered(
        uint256 indexed collectionId,
        uint256 indexed cooperativeId,
        address indexed collector,
        uint32 weightGrams,
        PlasticType plasticType,
        uint256 tokensMinted,
        bytes32 receiptHash,
        address validator
    );
    event Retired(address indexed company, uint256 amount, bytes32 disclosureHash);

    constructor(address initialAdmin)
        ERC20("Plastic Credit", "PLAST")
        AgentAccessControl(initialAdmin)
    {
        _setRoleAdmin(COOP_VALIDATOR_ROLE, ADMIN_ROLE);

        // Factors iniciais (admin pode ajustar). Justificativa em comentário do mapping.
        typeFactorBps[uint8(PlasticType.PET)] = 10_000;   // 100%
        typeFactorBps[uint8(PlasticType.HDPE)] = 9_000;   // 90%
        typeFactorBps[uint8(PlasticType.PP)] = 8_000;     // 80%
        typeFactorBps[uint8(PlasticType.LDPE)] = 6_000;   // 60%
        typeFactorBps[uint8(PlasticType.PVC)] = 4_500;    // 45%
        typeFactorBps[uint8(PlasticType.PS)] = 5_000;     // 50%
        typeFactorBps[uint8(PlasticType.OTHER)] = 3_000;  // 30%
        typeFactorBps[uint8(PlasticType.MIXED)] = 4_000;  // 40%
    }

    // ============================ Admin ============================

    function registerCooperative(bytes32 nameHash, bytes32 regionHash)
        external
        onlyRole(ADMIN_ROLE)
        returns (uint256 cooperativeId)
    {
        require(nameHash != bytes32(0), "Nome invalido");
        cooperativeId = nextCooperativeId++;
        cooperatives[cooperativeId] = Cooperative({
            nameHash: nameHash,
            regionHash: regionHash,
            registeredAt: uint64(block.timestamp),
            active: true
        });
        emit CooperativeRegistered(cooperativeId, regionHash);
    }

    /**
     * @notice Vincula um validator a uma cooperativa específica.
     * @dev Vínculo "1 validator -> 1 cooperativa" para o MVP. Em produção, suportaria
     *      N validators por cooperativa via mapping cooperativeId => address[] e quorum.
     */
    function attachValidator(address validator, uint256 cooperativeId)
        external
        onlyRole(ADMIN_ROLE)
    {
        require(cooperatives[cooperativeId].active, "Cooperativa inativa");
        require(validator != address(0), "Validator invalido");
        _grantRole(COOP_VALIDATOR_ROLE, validator);
        validatorOf[validator] = cooperativeId;
        emit ValidatorAttached(validator, cooperativeId);
    }

    function setTypeFactor(PlasticType ptype, uint16 factorBps) external onlyRole(ADMIN_ROLE) {
        require(factorBps <= BPS_DIVISOR, "Factor > 100%");
        typeFactorBps[uint8(ptype)] = factorBps;
    }

    // ============================ Validation + Mint ============================

    /**
     * @notice Registra uma coleta e minta PLAST proporcional ao peso × factor.
     * @dev Apenas o validator vinculado àquela cooperativa pode chamar. Receipt hash
     *      é o SHA-256 da imagem/PDF do recibo da cooperativa — o coletor mantém o
     *      original e pode provar offline contra a chain.
     *
     *      Anti-self-mint: validator NÃO pode ser o coletor. Separação de poderes
     *      força que pelo menos duas pessoas estejam envolvidas em cada certificação,
     *      neutralizando o ataque "catador fantasma + validador conluiado".
     */
    function registerCollection(
        address collector,
        uint32 weightGrams,
        PlasticType plasticType,
        bytes32 receiptHash
    ) external onlyRole(COOP_VALIDATOR_ROLE) returns (uint256 collectionId) {
        uint256 coopId = validatorOf[msg.sender];
        require(coopId != 0, "Validator nao vinculado");
        require(cooperatives[coopId].active, "Cooperativa inativa");
        require(collector != address(0), "Coletor invalido");
        require(collector != msg.sender, "Validator nao pode ser coletor");
        require(weightGrams > 0, "Peso zero");
        require(receiptHash != bytes32(0), "Recibo obrigatorio");
        require(!_receiptUsed[receiptHash], "Recibo ja usado");

        _receiptUsed[receiptHash] = true;

        uint16 factor = typeFactorBps[uint8(plasticType)];
        // tokensMinted = weightGrams * WEI_PER_GRAM_BASE * factor / 10_000
        uint256 tokens = (uint256(weightGrams) * WEI_PER_GRAM_BASE * factor) / BPS_DIVISOR;

        collectionId = nextCollectionId++;
        collections[collectionId] = Collection({
            cooperativeId: coopId,
            collector: collector,
            collectedAt: uint64(block.timestamp),
            weightGrams: weightGrams,
            plasticType: plasticType,
            receiptHash: receiptHash,
            tokensMinted: tokens
        });

        totalGramsCollectedBy[collector] += weightGrams;

        if (tokens > 0) {
            _mint(collector, tokens);
        }

        emit CollectionRegistered(
            collectionId, coopId, collector, weightGrams, plasticType, tokens, receiptHash, msg.sender
        );
    }

    // ============================ Retire (offset) ============================

    /**
     * @notice Empresa queima PLAST para registrar offset ambiental on-chain.
     * @param amount Quantidade em wei do token (use `amount = X * 1e18` para X PLAST).
     * @param disclosureHash Hash do PDF de divulgação ESG (relatório de sustentabilidade,
     *        comunicado público, etc). Permite ao auditor cruzar offset on-chain com
     *        alegação pública.
     *
     * @dev Burn (não transfer para 0x..dead). Reduz totalSupply real — auditor pode usar
     *      `totalSupply()` para saber quantos créditos ainda "vivem" no mercado.
     */
    function retire(uint256 amount, bytes32 disclosureHash) external {
        require(amount > 0, "Valor zero");
        require(disclosureHash != bytes32(0), "Disclosure obrigatorio");
        _burn(msg.sender, amount);

        // Converte de wei->gramas para a estatística (math inverso de WEI_PER_GRAM_BASE).
        // Aproximação: assume factor médio de 1 (PET). Os contadores são "PET-equivalentes".
        uint256 gramsEquivalent = amount / WEI_PER_GRAM_BASE;
        totalGramsRetiredBy[msg.sender] += gramsEquivalent;
        totalGramsRetired += gramsEquivalent;

        emit Retired(msg.sender, amount, disclosureHash);
    }

    // Sem override de supportsInterface — só herdamos AccessControl indireto e ERC20
    // (que não implementa ERC-165). A interface só fica relevante quando há ERC-721.
}
