// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {AgentAccessControl} from "../shared/AgentAccessControl.sol";

/**
 * @title MealRelay — MealRelay
 * @notice Pagamento por refeição validada para cozinhas comunitárias.
 *
 * @dev Mecânica:
 *      - Admin cadastra cozinhas (operador + região + preço-por-refeição).
 *      - Doadores fundam uma cozinha específica em USDC (`donate(kitchenId)`).
 *      - O operador da cozinha submete eventos de serviço: "servi X refeições em
 *        Y data, foto anexada (hash), GPS aqui". Vai para estado PENDING.
 *      - Validador da organização guarda-chuva (ONG mãe, governo municipal) checa
 *        e chama `validateAndPay(eventId)` → contrato libera price × count em USDC
 *        para o operador.
 *
 *      Por que pay-per-event (e não milestone como ReForest+):
 *      - Refeição é evento discreto, granular, frequente. Doador quer "doar 100
 *        refeições" não "comprar 30% do projeto".
 *      - Audita-se cada refeição individualmente (foto + GPS + assinatura
 *        validador) — sem agregação que esconde.
 *
 *      Por que NÃO armazenar foto on-chain:
 *      - 1 foto = ~100KB. Impagável em gas. Armazenamos só o hash SHA-256.
 *      - Operador mantém fotos em IPFS / Google Drive da ONG; auditor cruza.
 *
 *      Defesa anti-fraude:
 *      - Validador NÃO pode ser o operador da cozinha (separação de poderes
 *        igual ao EcoStream).
 *      - Cada evento só pode ser validado UMA vez.
 *      - Preço por refeição é fixado no cadastro — operador não pode "ajustar"
 *        preço por evento e tirar mais do cofre.
 *      - Donations isoladas por cozinha (`funded[kitchen]`). Pagamento de uma
 *        cozinha NÃO drena fundos de outra.
 *
 *      Limites duros:
 *      - `mealCount` <= 5_000 por evento (sanity: nenhuma cozinha serve mais
 *        que isso em um dia — evita typo ou ataque catastrófico).
 */
contract MealRelay is AgentAccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant ORG_VALIDATOR_ROLE = keccak256("MEALRELAY_ORG_VALIDATOR_ROLE");

    uint32 public constant MAX_MEALS_PER_EVENT = 5_000;

    IERC20 public immutable token;

    struct Kitchen {
        address operator;
        bytes32 districtHash;        // hash do bairro/CEP
        uint128 pricePerMeal;        // USDC wei por refeição
        uint128 funded;              // total já doado
        uint128 spent;               // total já pago ao operador
        uint64 mealsServed;          // contador cumulativo de refeições validadas
        bool exists;
    }

    struct MealEvent {
        uint256 kitchenId;
        uint64 submittedAt;
        uint64 validatedAt;          // 0 enquanto pendente
        uint32 mealCount;
        bytes32 photoHash;           // SHA-256 da foto (IPFS reference off-chain)
        int32 latE6;
        int32 lngE6;
        bool paid;
    }

    mapping(uint256 => Kitchen) public kitchens;
    mapping(uint256 => MealEvent) public events;

    uint256 public nextKitchenId = 1;
    uint256 public nextEventId = 1;

    // ============================ Events ============================

    event KitchenRegistered(uint256 indexed kitchenId, address indexed operator, uint128 pricePerMeal);
    event Donated(uint256 indexed kitchenId, address indexed donor, uint128 amount);
    event MealEventSubmitted(
        uint256 indexed eventId,
        uint256 indexed kitchenId,
        uint32 mealCount,
        bytes32 photoHash,
        address indexed operator,
        int32 latE6,
        int32 lngE6
    );
    event MealEventValidated(uint256 indexed eventId, uint256 indexed kitchenId, uint128 payout);

    constructor(address initialAdmin, IERC20 token_) AgentAccessControl(initialAdmin) {
        token = token_;
        _setRoleAdmin(ORG_VALIDATOR_ROLE, ADMIN_ROLE);
    }

    // ============================ Admin ============================

    function registerKitchen(address operator, bytes32 districtHash, uint128 pricePerMeal)
        external
        onlyRole(ADMIN_ROLE)
        returns (uint256 kitchenId)
    {
        require(operator != address(0), "Operador invalido");
        require(pricePerMeal > 0, "Preco invalido");
        kitchenId = nextKitchenId++;
        kitchens[kitchenId] = Kitchen({
            operator: operator,
            districtHash: districtHash,
            pricePerMeal: pricePerMeal,
            funded: 0,
            spent: 0,
            mealsServed: 0,
            exists: true
        });
        emit KitchenRegistered(kitchenId, operator, pricePerMeal);
    }

    // ============================ Donor ============================

    function donate(uint256 kitchenId, uint128 amount) external nonReentrant {
        Kitchen storage k = kitchens[kitchenId];
        require(k.exists, "Cozinha inexistente");
        require(amount > 0, "Valor zero");
        token.safeTransferFrom(msg.sender, address(this), amount);
        k.funded += amount;
        emit Donated(kitchenId, msg.sender, amount);
    }

    // ============================ Operator ============================

    /**
     * @notice Operador submete evento de refeições servidas.
     * @dev Vai para estado pendente — não paga ainda. Validador da ONG
     *      mãe confirma e chama `validateAndPay` para liberar fundos.
     */
    function submitMealEvent(
        uint256 kitchenId,
        uint32 mealCount,
        bytes32 photoHash,
        int32 latE6,
        int32 lngE6
    ) external returns (uint256 eventId) {
        Kitchen storage k = kitchens[kitchenId];
        require(k.exists, "Cozinha inexistente");
        require(msg.sender == k.operator, "Apenas operador");
        require(mealCount > 0 && mealCount <= MAX_MEALS_PER_EVENT, "Count invalido");
        require(photoHash != bytes32(0), "Foto obrigatoria");

        eventId = nextEventId++;
        events[eventId] = MealEvent({
            kitchenId: kitchenId,
            submittedAt: uint64(block.timestamp),
            validatedAt: 0,
            mealCount: mealCount,
            photoHash: photoHash,
            latE6: latE6,
            lngE6: lngE6,
            paid: false
        });
        emit MealEventSubmitted(eventId, kitchenId, mealCount, photoHash, msg.sender, latE6, lngE6);
    }

    /**
     * @notice Validador confirma o evento e libera o pagamento ao operador.
     * @dev Pagamento = mealCount × kitchen.pricePerMeal. Falha se a cozinha
     *      não tem saldo suficiente (`funded - spent`) — força o validador
     *      a aguardar nova doação ou ajustar a janela de submissão.
     *
     *      Validador NÃO pode ser o operador da cozinha — separação de poderes
     *      hard-enforced. Mesmo que o admin distribua a role ao operador por
     *      erro, a chamada reverte na hora.
     */
    function validateAndPay(uint256 eventId)
        external
        onlyRole(ORG_VALIDATOR_ROLE)
        nonReentrant
    {
        MealEvent storage e = events[eventId];
        require(e.kitchenId != 0, "Evento inexistente");
        require(!e.paid, "Ja validado");

        Kitchen storage k = kitchens[e.kitchenId];
        require(msg.sender != k.operator, "Validator nao pode ser operador");

        uint128 payout = uint128(uint256(e.mealCount) * uint256(k.pricePerMeal));
        require(k.funded - k.spent >= payout, "Saldo da cozinha insuficiente");

        // CEI: marca pago ANTES de transferir.
        e.paid = true;
        e.validatedAt = uint64(block.timestamp);
        k.spent += payout;
        k.mealsServed += e.mealCount;

        token.safeTransfer(k.operator, payout);
        emit MealEventValidated(eventId, e.kitchenId, payout);
    }

    // ============================ Views ============================

    function availableBalanceOf(uint256 kitchenId) external view returns (uint128) {
        Kitchen memory k = kitchens[kitchenId];
        if (!k.exists) return 0;
        return k.funded - k.spent;
    }

    function avgCostPerMeal(uint256 kitchenId) external view returns (uint256) {
        Kitchen memory k = kitchens[kitchenId];
        if (k.mealsServed == 0) return 0;
        return uint256(k.spent) / uint256(k.mealsServed);
    }
}
