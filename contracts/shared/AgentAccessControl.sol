// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title AgentAccessControl
 * @notice Camada de papéis funcionais reutilizada pelos contratos das 3 trilhas.
 *
 * @dev Por que herdar do AccessControl da OpenZeppelin em vez de implementar do zero:
 *      o módulo da OZ é auditado, suporta enumeração de membros (útil quando o oráculo
 *      sai do ar e precisamos saber para quem ligar) e tem o `onlyRole` modifier pronto.
 *
 *      Os papéis aqui são "genéricos de domínio" — cada contrato concreto define os seus
 *      próprios papéis específicos via `keccak256("MEU_PAPEL_AQUI")`. Esta base só fornece
 *      o ADMIN e helpers de bootstrap.
 *
 *      Nunca exposemos o DEFAULT_ADMIN_ROLE da OZ diretamente — usamos um ADMIN_ROLE
 *      próprio para sinalizar que o admin do CONTRATO não é necessariamente o admin do
 *      sistema, e para reduzir o blast radius de uma chave admin comprometida.
 */
abstract contract AgentAccessControl is AccessControl {
    /// @notice Papel administrativo do contrato. Pode conceder/revogar todos os outros papéis.
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /**
     * @param initialAdmin Endereço que recebe ADMIN_ROLE no constructor.
     * @dev Aceitamos o admin como parâmetro (em vez de usar msg.sender) porque na
     *      maioria dos deploys o deployer é uma EOA de pipeline CI/CD que NÃO deve
     *      reter poder administrativo após o setup. O script de deploy passa o
     *      multisig/governance address como initialAdmin.
     */
    constructor(address initialAdmin) {
        require(initialAdmin != address(0), "Admin nao pode ser zero");

        // Configuramos ADMIN_ROLE como o "manager" de si mesmo: quem é admin pode
        // promover outros admins. Em um cenário com multisig isso é seguro; com EOA
        // única é o risco de centralização (assumido para MVP de hackathon).
        _setRoleAdmin(ADMIN_ROLE, ADMIN_ROLE);
        _grantRole(ADMIN_ROLE, initialAdmin);

        // Também damos DEFAULT_ADMIN_ROLE para o initialAdmin porque a OZ usa ele
        // implicitamente como manager-padrão dos novos papéis criados via _setRoleAdmin.
        // Sem isso, quando um contrato derivado fizer _setRoleAdmin(NEW_ROLE, ADMIN_ROLE),
        // os usuários ADMIN_ROLE não conseguirão grant porque o role admin do NEW_ROLE
        // seria DEFAULT_ADMIN_ROLE — que ninguém possui.
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
    }

    /**
     * @notice Concede um papel a um endereço, restrito a quem tem ADMIN_ROLE.
     * @dev Wrapper conveniente que falha cedo se o caller não for admin. A OZ já
     *      tem `grantRole` público mas com modifier baseado no role admin do role
     *      sendo concedido — confuso. Esta função explicita que ADMIN_ROLE governa.
     */
    function grantRoleByAdmin(bytes32 role, address account) external onlyRole(ADMIN_ROLE) {
        _grantRole(role, account);
    }

    /**
     * @notice Revoga um papel de um endereço. Mesmo critério acima.
     * @dev Importante para resposta a incidentes: chave de oráculo vazada → revoga
     *      em segundos sem precisar redeployar o contrato inteiro.
     */
    function revokeRoleByAdmin(bytes32 role, address account) external onlyRole(ADMIN_ROLE) {
        _revokeRole(role, account);
    }
}
