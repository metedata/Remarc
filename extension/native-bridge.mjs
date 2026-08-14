export const NativeBridgeState = Object.freeze({
  DISCONNECTED: "disconnected",
  CONNECTING: "connecting",
  CONNECTED: "connected",
});

export const NATIVE_KEEPALIVE_INTERVAL_MS = 20_000;

const KEEPALIVE_ENVELOPE = Object.freeze({
  type: "tabActivity",
  data: Object.freeze({ reason: "keepalive" }),
});

const WEB_SOCKET_OPEN = 1;
const WEB_SOCKET_CLOSED = 3;

/**
 * Owns one WebSocket connection to the native Remarc app.
 *
 * Reconnect scheduling deliberately stays outside this class. Manifest V3
 * service workers cannot rely on a long-lived JavaScript timeout while the
 * native app is unavailable, so `onReconnectNeeded` is expected to arrange a
 * wakeable retry (for example, a chrome.alarms alarm).
 */
export class NativeBridge {
  constructor({
    url,
    WebSocketImpl = globalThis.WebSocket,
    setIntervalFn = globalThis.setInterval?.bind(globalThis),
    clearIntervalFn = globalThis.clearInterval?.bind(globalThis),
    onStateChange = () => {},
    onMessage = () => {},
    onReconnectNeeded = () => {},
    keepaliveIntervalMs = NATIVE_KEEPALIVE_INTERVAL_MS,
  } = {}) {
    if (typeof url !== "string" || url.length === 0) {
      throw new TypeError("NativeBridge requires a WebSocket URL");
    }
    if (typeof WebSocketImpl !== "function") {
      throw new TypeError("NativeBridge requires a WebSocket implementation");
    }
    if (typeof setIntervalFn !== "function" || typeof clearIntervalFn !== "function") {
      throw new TypeError("NativeBridge requires interval timer functions");
    }
    if (!Number.isFinite(keepaliveIntervalMs) || keepaliveIntervalMs <= 0) {
      throw new TypeError("NativeBridge requires a positive keepalive interval");
    }

    this._url = url;
    this._WebSocketImpl = WebSocketImpl;
    this._setInterval = setIntervalFn;
    this._clearInterval = clearIntervalFn;
    this._onStateChange = onStateChange;
    this._onMessage = onMessage;
    this._onReconnectNeeded = onReconnectNeeded;
    this._keepaliveIntervalMs = keepaliveIntervalMs;

    this._state = NativeBridgeState.DISCONNECTED;
    this._socket = null;
    this._generation = 0;
    this._keepaliveTimer = null;
    this._reconnectNeeded = false;
    this._intentionalStop = false;
  }

  get state() {
    return this._state;
  }

  /**
   * Starts a connection attempt unless one is already connecting or open.
   * Returns true only when a new WebSocket attempt was created.
   */
  connect() {
    if (
      this._socket !== null ||
      this._state === NativeBridgeState.CONNECTING ||
      this._state === NativeBridgeState.CONNECTED
    ) {
      return false;
    }

    this._intentionalStop = false;
    const generation = ++this._generation;
    this._setState(NativeBridgeState.CONNECTING);

    let socket;
    try {
      socket = new this._WebSocketImpl(this._url);
    } catch {
      if (generation === this._generation) {
        this._setState(NativeBridgeState.DISCONNECTED);
        this._requestReconnect();
      }
      return false;
    }

    this._socket = socket;
    socket.onopen = () => this._handleOpen(socket, generation);
    socket.onmessage = (event) => this._handleMessage(socket, generation, event);
    socket.onerror = () => this._handleDisconnect(socket, generation, true);
    socket.onclose = () => this._handleDisconnect(socket, generation, false);
    return true;
  }

  /**
   * Clears the outstanding reconnect latch and attempts a connection now.
   * This is called by an alarm or an explicit popup retry.
   */
  retryNow() {
    this._reconnectNeeded = false;
    this._intentionalStop = false;
    return this.connect();
  }

  /**
   * Sends one native-protocol envelope. The boolean return value is the
   * delivery acknowledgement used by content scripts to retain or remove
   * their in-memory queued payload.
   */
  send(envelope) {
    const socket = this._socket;
    if (this._state !== NativeBridgeState.CONNECTED || socket === null) {
      return false;
    }

    const generation = this._generation;
    if (socket.readyState !== WEB_SOCKET_OPEN) {
      this._handleDisconnect(socket, generation, true);
      return false;
    }

    let payload;
    try {
      payload = JSON.stringify(envelope);
      if (typeof payload !== "string") return false;
    } catch {
      return false;
    }

    try {
      socket.send(payload);
      return true;
    } catch {
      this._handleDisconnect(socket, generation, true);
      return false;
    }
  }

  /**
   * Intentionally shuts down the bridge. Generation invalidation happens
   * before close(), so a synchronous or late close callback cannot schedule a
   * reconnect or demote a later replacement socket.
   */
  stop() {
    this._intentionalStop = true;
    this._reconnectNeeded = false;
    this._clearKeepalive();

    const socket = this._socket;
    this._socket = null;
    this._generation += 1;
    this._setState(NativeBridgeState.DISCONNECTED);

    if (socket !== null && socket.readyState !== WEB_SOCKET_CLOSED) {
      try {
        socket.close();
      } catch {
        // The generation was already invalidated; shutdown is complete.
      }
    }
  }

  _isCurrent(socket, generation) {
    return (
      !this._intentionalStop &&
      this._socket === socket &&
      this._generation === generation
    );
  }

  _handleOpen(socket, generation) {
    if (!this._isCurrent(socket, generation)) return;
    this._reconnectNeeded = false;
    this._setState(NativeBridgeState.CONNECTED);
    this._startKeepalive();
  }

  _handleMessage(socket, generation, event) {
    if (!this._isCurrent(socket, generation) || typeof event?.data !== "string") return;

    let message;
    try {
      message = JSON.parse(event.data);
    } catch {
      return;
    }

    try {
      this._onMessage(message, event);
    } catch {
      // A consumer callback must not break the socket event loop.
    }
  }

  _handleDisconnect(socket, generation, closeSocket) {
    if (!this._isCurrent(socket, generation)) return;

    this._socket = null;
    this._clearKeepalive();
    this._setState(NativeBridgeState.DISCONNECTED);

    if (closeSocket && socket.readyState !== WEB_SOCKET_CLOSED) {
      try {
        socket.close();
      } catch {
        // The socket is already detached from bridge state.
      }
    }

    this._requestReconnect();
  }

  _startKeepalive() {
    this._clearKeepalive();
    this._keepaliveTimer = this._setInterval(() => {
      this.send(KEEPALIVE_ENVELOPE);
    }, this._keepaliveIntervalMs);
  }

  _clearKeepalive() {
    if (this._keepaliveTimer === null) return;
    this._clearInterval(this._keepaliveTimer);
    this._keepaliveTimer = null;
  }

  _requestReconnect() {
    if (this._intentionalStop || this._reconnectNeeded) return;
    this._reconnectNeeded = true;
    try {
      this._onReconnectNeeded();
    } catch {
      // The latch prevents error+close from accumulating reconnect requests.
    }
  }

  _setState(nextState) {
    if (this._state === nextState) return;
    const previousState = this._state;
    this._state = nextState;
    try {
      this._onStateChange(nextState, previousState);
    } catch {
      // Status rendering must not interfere with transport lifecycle.
    }
  }
}
