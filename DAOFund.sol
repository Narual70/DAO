// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * DAOFund
 * @notice Fondo DAO simplificado con Partners, Spenders y Owner.
 */
contract DAOFund {
    
    uint256 public constant ENROLLMENT = 0.4 ether;
    uint256 public constant PERIODOVIGENTE = 24 hours;

    // =============================================================
    // ROLES Y ESTADO GENERAL
    // =============================================================

    /// @notice Wallet que despliega el contrato. No puede cambiar.
    address public immutable owner;

    mapping(address => bool) private partners;
    mapping(address => bool) private spenders;

    /// @notice Solicitudes pendientes de promoción a Spender.
    mapping(address => bool) private spenderPromocionSolicitada;

    /// @notice Listas para poder recorrer los miembros.
    address[] private partnerList;
    address[] private spenderList;

    /// @notice Cantidad de solicitudes creadas.
    uint256 private requestCount;

    /**
     * @notice ETH comprometido por solicitudes de gasto pendientes.
     *
     * El objetivo es evitar que varias solicitudes pendientes
     * comprometan simultáneamente los mismos fondos.
     */
    uint256 public reservedFunds;

    // =============================================================
    // SOLICITUDES DE GASTO
    // =============================================================

    enum RequestStatus {
        Pendiente,
        Ejecutada,
        Rechazada
    }

    struct SolicitudGasto {
        address payable destination;
        uint256 amount;
        uint256 deadline;

        uint256 requiredApprovals;
        uint256 approvals;

        RequestStatus status;

        /**
         * Fotografía de los votantes requeridos al momento
         * de crear la solicitud.
         */
        mapping(address => bool) requiredVoter;

        /**
         * Evita que una misma dirección vote dos veces.
         */
        mapping(address => bool) voted;
    }

    mapping(uint256 => SolicitudGasto) private requests;

    // =============================================================
    // EVENTOS
    // =============================================================

    event PartnerEnrolled(
        address indexed partner,
        uint256 amount
    );

    event PrimerSpenderDesignado(
        address indexed spender
    );

    event SpenderPromocionSolicitada(
        address indexed partner
    );

    event SpenderPromovido(
        address indexed partner
    );

    event SpenderPromovidoRechazado(
        address indexed partner
    );

    event SolicitudGastoCreado(
        uint256 indexed requestId,
        address indexed spender,
        address indexed destination,
        uint256 amount,
        uint256 deadline
    );

    event VoteCast(
        uint256 indexed requestId,
        address indexed voter
    );

    event GastoEjecutado(
        uint256 indexed requestId,
        address indexed destination,
        uint256 amount
    );

    event SolicitudGastoRechazado(
        uint256 indexed requestId
    );

    event MiembroRemovido(
        address indexed member
    );

    event FundsReceived(
        address indexed sender,
        uint256 amount
    );

    // =============================================================
    // MODIFIERS
    // =============================================================

    modifier SoloOwner() {
        require(msg.sender == owner, "solo owner");
        _;
    }

    modifier SoloPartner() {
        require(partners[msg.sender], "solo partner");
        _;
    }

    modifier SoloSpender() {
        require(spenders[msg.sender], "solo spender");
        _;
    }

    // =============================================================
    // CONSTRUCTOR
    // =============================================================

    constructor() {
        owner = msg.sender;
    }

    // =============================================================
    // PARTNERS
    // =============================================================

    /**
     * @notice Permite a una wallet convertirse en Partner.
     * @dev Debe enviar exactamente 0.4 ETH.
     */
    function enrollAsPartner() external payable {
        require(msg.sender != owner, "owner no puede ser partner");
        require(!partners[msg.sender], "ya es partner");
        require(msg.value == ENROLLMENT, "exactamente 0.4 ETH es solicitado");

        partners[msg.sender] = true;
        partnerList.push(msg.sender);

        emit PartnerEnrolled(msg.sender, msg.value);
    }

    // =============================================================
    // SPENDER INICIAL
    // =============================================================

    /**
     * @notice El Owner designa al primer Spender.
     *
     * Solo puede existir una designacion inicial.
     */
    function DesignarPrimerSpender(
        address spender
    ) external SoloOwner {
        require(spender != address(0), "direccion invalida");
        require(spender != owner, "owner no puede ser spender");
        require(!spenders[spender], "ya es spender");
        require(
            spenderList.length == 0,
            "primer spender ya designado"
        );

        spenders[spender] = true;
        spenderList.push(spender);

        emit PrimerSpenderDesignado(spender);
    }

    // =============================================================
    // PROMOCION A SPENDER
    // =============================================================

    /**
     * @notice Un Partner solicita convertirse en Spender.
     */
    function requestSpenderPromotion()
        external
        SoloPartner
    {
        require(
            !spenders[msg.sender],
            "ya es spender"
        );

        require(
            !spenderPromocionSolicitada[msg.sender],
            "promocion ya solicitada"
        );

        spenderPromocionSolicitada[msg.sender] = true;

        emit SpenderPromocionSolicitada(msg.sender);
    }

    /**
     * @notice El Owner acepta una solicitud de promocion.
     *
     * El usuario sigue siendo Partner despues de ser promovido.
     */
    function PromocionSpenderAceptada(
        address partner
    ) external SoloOwner {
        require(partners[partner], "no es un partner");
        require(!spenders[partner], "es spender");

        require(
            spenderPromocionSolicitada[partner],
            "sin promocion solicitada"
        );

        spenders[partner] = true;
        spenderList.push(partner);

        spenderPromocionSolicitada[partner] = false;

        emit SpenderPromovido(partner);
    }

    /**
     * @notice El Owner rechaza una solicitud de promocion.
     */
    function rejectSpenderPromotion(
        address partner
    ) external SoloOwner {
        require(
            spenderPromocionSolicitada[partner],
            "sin promocion solicitada"
        );

        spenderPromocionSolicitada[partner] = false;

        emit SpenderPromovidoRechazado(partner);
    }

    // =============================================================
    // CREACION DE SOLICITUDES DE GASTO
    // =============================================================

    /**
     * @notice Crea una solicitud de transferencia.
     *
     * La solicitud permanece abierta durante 24 horas.
     *
     * Al crearla se toma una fotografia de los votantes
     * que deben aprobarla.
     */
    function CreateSolicitudGasto(
        address payable destination,
        uint256 amount
    )
        external
        SoloSpender
        returns (uint256 requestId)
    {
        require(
            destination != address(0),
            "destinacion invalida"
        );

        require(
            destination != owner,
            "owner no puede ser destino"
        );

        require(
            destination != msg.sender,
            "spender no puede pagarse asi mismo"
        );

        require(
            !partners[destination],
            "partner no puede ser el destino"
        );

        require(
            amount > 0,
            "el monto debe ser mayor a cero"
        );

        /**
         * Solo consideramos disponible el balance que no esta
         * comprometido por otras solicitudes pendientes.
         */
        uint256 availableFunds =
            address(this).balance - reservedFunds;

        require(
            amount <= availableFunds,
            "fondos insuficientes"
        );

        requestId = requestCount;
        requestCount++;

        SolicitudGasto storage request =
            requests[requestId];

        request.destination = destination;
        request.amount = amount;
        request.deadline =
            block.timestamp + PERIODOVIGENTE;
        request.status = RequestStatus.Pendiente;

        // ---------------------------------------------------------
        // Owner forma parte del conjunto de votantes.
        // ---------------------------------------------------------

        request.requiredVoter[owner] = true;
        request.requiredApprovals++;

        // ---------------------------------------------------------
        // Partners actuales.
        // ---------------------------------------------------------

        for (uint256 i = 0; i < partnerList.length; i++) {
            address member = partnerList[i];

            if (
                partners[member] &&
                !request.requiredVoter[member]
            ) {
                request.requiredVoter[member] = true;
                request.requiredApprovals++;
            }
        }

        // ---------------------------------------------------------
        // Spenders actuales.
        //
        // Si ya es Partner, no se agrega una segunda vez.
        // ---------------------------------------------------------

        for (uint256 i = 0; i < spenderList.length; i++) {
            address member = spenderList[i];

            if (
                spenders[member] &&
                !request.requiredVoter[member]
            ) {
                request.requiredVoter[member] = true;
                request.requiredApprovals++;
            }
        }

        reservedFunds += amount;

        emit SolicitudGastoCreado(
            requestId,
            msg.sender,
            destination,
            amount,
            request.deadline
        );

        return requestId;
    }

    // =============================================================
    // VOTACION
    // =============================================================

    /**
     * @notice Aprueba una solicitud de gasto.
     *
     * Cada wallet puede votar una sola vez.
     */
    function AprobarGasto(
        uint256 requestId
    ) external {
        require(
            requestId < requestCount,
            "id  invalido"
        );

        SolicitudGasto storage request =
            requests[requestId];

        require(
            request.status == RequestStatus.Pendiente,
            "la solicitud no esta pendiente"
        );

        require(
            block.timestamp <= request.deadline,
            "el periodo de votacion termino"
        );

        require(
            request.requiredVoter[msg.sender],
            "no es un votante obligatorio"
        );

        require(
            !request.voted[msg.sender],
            "ya voto"
        );

        request.voted[msg.sender] = true;
        request.approvals++;

        emit VoteCast(
            requestId,
            msg.sender
        );

        /**
         * Si todos los votantes requeridos aprobaron,
         * la transferencia se ejecuta automaticamente.
         */
        if (
            request.approvals ==
            request.requiredApprovals
        ) {
            _executeExpense(requestId);
        }
    }

    // =============================================================
    // RECHAZO POR OWNER
    // =============================================================

    /**
     * @notice Permite al Owner rechazar una solicitud pendiente.
     *
     * Esto implementa explicitamente la capacidad del Owner
     * de rechazar una solicitud de gasto.
     */
    function RechazasSolicitudGasto(
        uint256 requestId
    ) external SoloOwner {
        require(
            requestId < requestCount,
            "id  invalido"
        );

        SolicitudGasto storage request =
            requests[requestId];

        require(
            request.status == RequestStatus.Pendiente,
            "la solicitud no esta pendiente"
        );

        request.status = RequestStatus.Rechazada;

        reservedFunds -= request.amount;

        emit SolicitudGastoRechazado(requestId);
    }

    // =============================================================
    // VENCIMIENTO
    // =============================================================

    /**
     * @notice Marca como rechazada una solicitud cuyo plazo
     * de 24 horas ya vencio.
     *
     * Ethereum no ejecuta funciones automaticamente cuando
     * llega una fecha, por eso se utiliza este mecanismo
     * de expiracion "lazy": cualquier persona puede llamarlo.
     */
    function RechazarSolicitudCaduco(
        uint256 requestId
    ) external {
        require(
            requestId < requestCount,
            "id invalido"
        );

        SolicitudGasto storage request =
            requests[requestId];

        require(
            request.status == RequestStatus.Pendiente,
            "la solicitud no esta pendiente"
        );

        require(
            block.timestamp > request.deadline,
            "el tiempo limite no ha expirado"
        );

        request.status = RequestStatus.Rechazada;

        reservedFunds -= request.amount;

        emit SolicitudGastoRechazado(requestId);
    }

    // =============================================================
    // EJECUCION INTERNA
    // =============================================================

    /**
     * @dev Ejecuta una solicitud que alcanzo unanimidad.
     */
    function _executeExpense(
        uint256 requestId
    ) internal {
        SolicitudGasto storage request =
            requests[requestId];

        require(
            request.status == RequestStatus.Pendiente,
            "la solicitud no esta pendiente"
        );

        require(
            request.approvals ==
                request.requiredApprovals,
            "no es unanime"
        );

        require(
            address(this).balance >= request.amount,
            "saldo insuficiente en el contrato"
        );

        /**
         * Cambiamos el estado antes de realizar la llamada
         * externa para evitar que una reentrada pueda ejecutar
         * nuevamente la misma solicitud.
         */
        request.status = RequestStatus.Ejecutada;

        reservedFunds -= request.amount;

        (bool success, ) =
            request.destination.call{
                value: request.amount
            }("");

        require(
            success,
            "fallo transferencia"
        );

        emit GastoEjecutado(
            requestId,
            request.destination,
            request.amount
        );
    }

    // =============================================================
    // EXPULSION DE MIEMBROS
    // =============================================================

    /**
     * @notice El Owner expulsa un Partner, Spender o ambos.
     *
     * Las solicitudes ya creadas mantienen su conjunto de
     * votantes original. La expulsion afecta las solicitudes
     * creadas posteriormente.
     *
     * El aporte de 0.4 ETH no se devuelve.
     */
    function RemoveMiembro(
        address member
    ) external SoloOwner {
        require(
            member != owner,
            "owner no puede ser removido"
        );

        require(
            partners[member] || spenders[member],
            "la direccion no es de un miembro activo"
        );

        if (partners[member]) {
            partners[member] = false;
        }

        if (spenders[member]) {
            spenders[member] = false;
        }

        spenderPromocionSolicitada[member] = false;

        emit MiembroRemovido(member);
    }

    // =============================================================
    // FUNCIONES VIEW
    // =============================================================

    function esPartner(
        address account
    ) external view returns (bool) {
        return partners[account];
    }

    function esSpender(
        address account
    ) external view returns (bool) {
        return spenders[account];
    }

    function SpendertieneSolicitudAscenso(
        address account
    ) external view returns (bool) {
        return spenderPromocionSolicitada[account];
    }

    function ObtenerBalance()
        external
        view
        returns (uint256)
    {
        return address(this).balance;
    }

    function ObtenerBalanceDisponible()
        external
        view
        returns (uint256)
    {
        return address(this).balance - reservedFunds;
    }

    function ObtenerConteoSolicitudes()
        external
        view
        returns (uint256)
    {
        return requestCount;
    }

    function ObtenerSolicitudGasto(
        uint256 requestId
    )
        external
        view
        returns (
            address destination,
            uint256 amount,
            uint256 deadline,
            uint256 requiredApprovals,
            uint256 approvals,
            RequestStatus status
        )
    {
        require(
            requestId < requestCount,
            "id invalida"
        );

        SolicitudGasto storage request =
            requests[requestId];

        return (
            request.destination,
            request.amount,
            request.deadline,
            request.requiredApprovals,
            request.approvals,
            request.status
        );
    }

    function esvotanteobligatorio(
        uint256 requestId,
        address voter
    ) external view returns (bool) {
        require(
            requestId < requestCount,
            "id invalida"
        );

        return requests[requestId]
            .requiredVoter[voter];
    }

    function haVotado(
        uint256 requestId,
        address voter
    ) external view returns (bool) {
        require(
            requestId < requestCount,
            "id invalida"
        );

        return requests[requestId]
            .voted[voter];
    }

    function ObtenerLongListaSocios()
        external
        view
        returns (uint256)
    {
        return partnerList.length;
    }

    function ObtenerLongListaSpender()
        external
        view
        returns (uint256)
    {
        return spenderList.length;
    }

    function ObtenerPartnerEn(
        uint256 index
    ) external view returns (address) {
        require(
            index < partnerList.length,
            "index fuera de limites"
        );

        return partnerList[index];
    }

    function ObtenerSpenderEn(
        uint256 index
    ) external view returns (address) {
        require(
            index < spenderList.length,
            "index fuera de limites"
        );

        return spenderList[index];
    }

    // =============================================================
    // RECEPCION DE ETH
    // =============================================================

    /**
     * @notice Permite enviar ETH directamente al fondo.
     *
     * Recibir ETH de esta forma NO convierte al remitente
     * automaticamente en Partner.
     */
    receive() external payable {
        emit FundsReceived(
            msg.sender,
            msg.value
        );
    }
}

