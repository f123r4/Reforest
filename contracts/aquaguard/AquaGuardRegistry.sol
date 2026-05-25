// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AgentAccessControl} from "../shared/AgentAccessControl.sol";

/**
 * @title AquaGuardRegistry — AquaGuard
 * @notice Monitoramento on-chain de qualidade hídrica com agregação multi-guardião
 *         e alerta automático contra threshold da Resolução CONAMA 357/2005 (Classe 2).
 *
 * @dev Mecânica:
 *      - Estações de monitoramento são cadastradas pelo admin com thresholds.
 *      - Múltiplos guardiões (sensores IoT, voluntários treinados, ONGs) submetem
 *        leituras de pH, oxigênio dissolvido (DO) e turbidez por época (epoch).
 *      - Após o epoch fechar, qualquer um pode chamar `finalizeEpoch` — o contrato
 *        calcula a MÉDIA das leituras, valida contra threshold e:
 *          a) emite AlertRaised se algum parâmetro estiver fora da banda
 *          b) atualiza reputação cumulativa dos guardiões cujas leituras se mantiveram
 *             dentro de tolerância de ±15% da média (anti-spam/anti-fraude estatístico).
 *
 *      Por que MÉDIA e não mediana:
 *      - Mediana on-chain exige sort em storage. O(n log n) em gas. Inviável.
 *      - Para 3-10 guardiões honestos, média e mediana convergem; outlier único
 *        é tratado via tolerância na reputação (não distorce a decisão de alerta).
 *      - O modelo de threat aqui é "guardião preguiçoso copia leitura padrão",
 *        não "guardião adversarial coordenado" — a média + tolerância já cobre.
 *
 *      Por que NÃO usar oráculo Chainlink:
 *      - Custo: cada round de oráculo Chainlink é $ — inviável para 1000 estações.
 *      - Independência: queremos comunidade local como fonte primária, com auditoria
 *        independente posterior. Oráculo único é ponto único de fraude.
 *
 *      Threshold defaults (CONAMA 357/2005 Classe 2 água doce):
 *      - pH em [6,00 ; 9,00]
 *      - DO >= 5,00 mg/L
 *      - Turbidez <= 100 NTU
 *
 *      Unidades escolhidas para evitar fixed-point:
 *      - pH armazenado *100 (int16: -32k..32k é folgado)
 *      - DO armazenado *100 mg/L (int32 suporta valores absurdos)
 *      - Turbidez em NTU inteiro (uint16: 0..65535 cobre eventos extremos)
 */
contract AquaGuardRegistry is AgentAccessControl {
    bytes32 public constant GUARDIAN_ROLE = keccak256("AQUAGUARD_GUARDIAN_ROLE");

    /// @dev Duração de cada época (janela de agregação). 1 dia balanceia frescor
    ///      do alerta vs gas: 1 finalização/dia/estação = ~365 tx/ano.
    uint64 public constant EPOCH_DURATION = 1 days;

    /// @dev Mínimo de leituras para considerar um epoch válido.
    ///      < 3 → muito ruído individual. 3 é o número usado pela ANA em estudos.
    uint8 public constant MIN_READINGS_PER_EPOCH = 3;

    /// @dev Tolerância (basis points) da leitura individual vs média do epoch para
    ///      contar como "leitura honesta" na reputação. 15% = 1_500.
    uint16 public constant REPUTATION_TOLERANCE_BPS = 1_500;
    uint16 public constant BPS_DIVISOR = 10_000;

    struct Station {
        bytes32 watershedId;        // hash da bacia + ponto (preserva GPS exato)
        int32 latE6;                // latitude * 1e6
        int32 lngE6;                // longitude * 1e6
        int16 phMinX100;            // ex: 600 (= pH 6.00)
        int16 phMaxX100;            // ex: 900
        int32 doMinX100;            // ex: 500 (= 5.00 mg/L)
        uint16 turbMaxNtu;          // ex: 100
        bool exists;
    }

    struct EpochAccumulator {
        // Soma das leituras (para média = sum/count, evitando divisão por epoch).
        int64 phSumX100;
        int64 doSumX100;
        uint64 turbSumNtu;
        uint8 reportCount;
        bool finalized;
    }

    struct Reading {
        address guardian;
        int16 phX100;
        int32 doX100;
        uint16 turbNtu;
    }

    mapping(uint256 => Station) public stations;
    /// @dev stationId => epochId (= timestamp / EPOCH_DURATION) => accumulator
    mapping(uint256 => mapping(uint64 => EpochAccumulator)) public epochs;
    /// @dev stationId => epochId => leituras (para que finalizeEpoch possa medir
    ///      a tolerância de cada guardião).
    mapping(uint256 => mapping(uint64 => Reading[])) internal _readings;
    /// @dev Evita o guardião reportar duas vezes no mesmo epoch (anti-spoof reputação).
    mapping(uint256 => mapping(uint64 => mapping(address => bool))) public hasReported;

    /// @dev Reputação cumulativa por guardião — vai para front-end de ranking.
    mapping(address => uint256) public honestReadingsBy;
    mapping(address => uint256) public totalReadingsBy;

    uint256 public nextStationId = 1;

    // ============================ Events ============================

    event StationRegistered(
        uint256 indexed stationId,
        bytes32 indexed watershedId,
        int32 latE6,
        int32 lngE6
    );
    event ReadingSubmitted(
        uint256 indexed stationId,
        uint64 indexed epochId,
        address indexed guardian,
        int16 phX100,
        int32 doX100,
        uint16 turbNtu
    );
    event EpochFinalized(
        uint256 indexed stationId,
        uint64 indexed epochId,
        int16 phMeanX100,
        int32 doMeanX100,
        uint16 turbMeanNtu,
        uint8 reportCount
    );
    /// @dev Disparado se QUALQUER parâmetro mediano cruzar threshold. UI escuta isto.
    event AlertRaised(
        uint256 indexed stationId,
        uint64 indexed epochId,
        uint8 violatedParameters     // bitmask: bit0=pH, bit1=DO, bit2=turbidez
    );

    constructor(address initialAdmin) AgentAccessControl(initialAdmin) {
        _setRoleAdmin(GUARDIAN_ROLE, ADMIN_ROLE);
    }

    // ============================ Station lifecycle ============================

    function registerStation(
        bytes32 watershedId,
        int32 latE6,
        int32 lngE6,
        int16 phMinX100,
        int16 phMaxX100,
        int32 doMinX100,
        uint16 turbMaxNtu
    ) external onlyRole(ADMIN_ROLE) returns (uint256 stationId) {
        require(watershedId != bytes32(0), "Watershed invalido");
        require(phMinX100 < phMaxX100, "pH min/max invertidos");
        stationId = nextStationId++;
        stations[stationId] = Station({
            watershedId: watershedId,
            latE6: latE6,
            lngE6: lngE6,
            phMinX100: phMinX100,
            phMaxX100: phMaxX100,
            doMinX100: doMinX100,
            turbMaxNtu: turbMaxNtu,
            exists: true
        });
        emit StationRegistered(stationId, watershedId, latE6, lngE6);
    }

    // ============================ Readings ============================

    /**
     * @notice Guardião submete uma leitura para o epoch atual.
     * @dev Idempotência por (station, epoch, guardian). Mesmo guardião reportando
     *      duas vezes no mesmo epoch reverte — evita inflar count para enviesar a
     *      média ou roubar reputação.
     */
    function submitReading(
        uint256 stationId,
        int16 phX100,
        int32 doX100,
        uint16 turbNtu
    ) external onlyRole(GUARDIAN_ROLE) {
        Station memory s = stations[stationId];
        require(s.exists, "Estacao inexistente");
        // Banda absurda permitida para input (sanity check, não threshold).
        require(phX100 > 0 && phX100 < 1_400, "pH fora de range plausivel");
        require(doX100 >= 0, "DO negativo invalido");

        uint64 epochId = uint64(block.timestamp / EPOCH_DURATION);
        require(!hasReported[stationId][epochId][msg.sender], "Ja reportou neste epoch");

        EpochAccumulator storage acc = epochs[stationId][epochId];
        require(!acc.finalized, "Epoch ja finalizado");

        hasReported[stationId][epochId][msg.sender] = true;
        acc.phSumX100 += int64(phX100);
        acc.doSumX100 += int64(doX100);
        acc.turbSumNtu += uint64(turbNtu);
        acc.reportCount += 1;

        _readings[stationId][epochId].push(
            Reading({guardian: msg.sender, phX100: phX100, doX100: doX100, turbNtu: turbNtu})
        );

        totalReadingsBy[msg.sender] += 1;

        emit ReadingSubmitted(stationId, epochId, msg.sender, phX100, doX100, turbNtu);
    }

    // ============================ Finalize + Alert ============================

    /**
     * @notice Fecha um epoch, calcula média, dispara alerta se threshold cruzado
     *         e atualiza reputação dos guardiões.
     * @dev Qualquer um pode chamar — incentivo via gas-back (não implementado no MVP)
     *      ou simplesmente ONGs/auditores fazendo varredura periódica.
     *
     *      Só funciona após o epoch ter passado (`block.timestamp >= (epochId+1) * EPOCH_DURATION`).
     */
    function finalizeEpoch(uint256 stationId, uint64 epochId) external {
        Station memory s = stations[stationId];
        require(s.exists, "Estacao inexistente");
        require(block.timestamp >= (epochId + 1) * EPOCH_DURATION, "Epoch ainda aberto");

        EpochAccumulator storage acc = epochs[stationId][epochId];
        require(!acc.finalized, "Epoch ja finalizado");
        require(acc.reportCount >= MIN_READINGS_PER_EPOCH, "Insuficientes leituras");

        acc.finalized = true;

        int16 phMean = int16(acc.phSumX100 / int64(uint64(acc.reportCount)));
        int32 doMean = int32(acc.doSumX100 / int64(uint64(acc.reportCount)));
        uint16 turbMean = uint16(acc.turbSumNtu / uint64(acc.reportCount));

        emit EpochFinalized(stationId, epochId, phMean, doMean, turbMean, acc.reportCount);

        // Threshold check.
        uint8 violations = 0;
        if (phMean < s.phMinX100 || phMean > s.phMaxX100) violations |= 1;
        if (doMean < s.doMinX100) violations |= 2;
        if (turbMean > s.turbMaxNtu) violations |= 4;
        if (violations > 0) {
            emit AlertRaised(stationId, epochId, violations);
        }

        // Reputação: cada guardião cuja leitura de pH e DO está dentro de ±15% da
        // média conta como "honesto". Turbidez fica de fora porque, sendo um valor
        // naturalmente pequeno (ex: 5..50 NTU em água saudável), 15% é apenas 1..7
        // unidades — abaixo da variância real de instrumentos diferentes. Forçar
        // turbidez como critério penalizaria guardiões honestos com sondas comuns.
        Reading[] storage rs = _readings[stationId][epochId];
        for (uint256 i = 0; i < rs.length; i++) {
            Reading memory r = rs[i];
            if (_withinTolerance(r.phX100, phMean) &&
                _withinTolerance32(r.doX100, doMean)
            ) {
                honestReadingsBy[r.guardian] += 1;
            }
        }
    }

    // ============================ Views ============================

    function getReadings(uint256 stationId, uint64 epochId)
        external
        view
        returns (Reading[] memory)
    {
        return _readings[stationId][epochId];
    }

    function currentEpoch() external view returns (uint64) {
        return uint64(block.timestamp / EPOCH_DURATION);
    }

    function reputation(address guardian)
        external
        view
        returns (uint256 honest, uint256 total, uint16 honestyBps)
    {
        honest = honestReadingsBy[guardian];
        total = totalReadingsBy[guardian];
        honestyBps = total == 0 ? 0 : uint16((honest * BPS_DIVISOR) / total);
    }

    // ============================ Internals ============================

    function _withinTolerance(int16 reading, int16 mean) private pure returns (bool) {
        if (mean == 0) return reading == 0;
        int32 diff = int32(reading) - int32(mean);
        if (diff < 0) diff = -diff;
        // |reading - mean| / |mean| <= tolerance
        return uint256(int256(diff)) * BPS_DIVISOR <= uint256(int256(_abs16(mean))) * REPUTATION_TOLERANCE_BPS;
    }

    function _withinTolerance32(int32 reading, int32 mean) private pure returns (bool) {
        if (mean == 0) return reading == 0;
        int64 diff = int64(reading) - int64(mean);
        if (diff < 0) diff = -diff;
        return uint256(int256(diff)) * BPS_DIVISOR <= uint256(int256(_abs32(mean))) * REPUTATION_TOLERANCE_BPS;
    }

    function _abs16(int16 x) private pure returns (int16) { return x < 0 ? -x : x; }
    function _abs32(int32 x) private pure returns (int32) { return x < 0 ? -x : x; }
}
