'use strict';
window.LegadoWebStream = (() => {
  const channels = new Set(['searchBook', 'bookSourceDebug', 'rssSourceDebug']);
  function create({request, getToken, onInfo}) {
    const sessions = new Map();
    let generation = 0;

    async function info(signal) {
      const value = await request('/getWebServiceInfo', undefined, {signal});
      if (signal?.aborted) throw new DOMException('Aborted', 'AbortError');
      if (!value || !Number.isInteger(value.socketPort) || value.socketPort < 1 || value.socketPort > 65535 || typeof value.allowsWrites !== 'boolean') {
        throw Error('Web 服务连接信息无效');
      }
      onInfo?.(value);
      return value;
    }

    function cancel(channel) {
      const session = sessions.get(channel);
      if (!session) return;
      sessions.delete(channel);
      session.controller.abort();
      clearTimeout(session.timer);
      const socket = session.socket;
      if (socket) {
        socket.onopen = socket.onmessage = socket.onerror = socket.onclose = null;
        if (socket.readyState < WebSocket.CLOSING) socket.close(1000, 'Cancelled');
      }
    }

    function cancelAll() {
      generation++;
      for (const channel of [...sessions.keys()]) cancel(channel);
    }

    async function start(channel, payload, callbacks = {}) {
      if (!channels.has(channel)) throw Error('不支持的 Web 流');
      cancel(channel);
      const revision = generation;
      const session = {controller: new AbortController(), socket: null, timer: null, failed: false};
      sessions.set(channel, session);
      const current = () => revision === generation && sessions.get(channel) === session;
      const fail = error => {
        if (!current() || session.failed) return;
        session.failed = true;
        cancel(channel);
        callbacks.onError?.(error instanceof Error ? error : Error(String(error)));
      };
      try {
        callbacks.onState?.('connecting');
        const service = await info(session.controller.signal);
        if (!current()) return;
        const token = getToken();
        if (!/^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/.test(token)) throw Error('密钥不适用于 WebSocket 协议，请重新连接');
        const url = new URL(location.origin);
        url.protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
        url.port = String(service.socketPort);
        url.pathname = '/' + channel;
        url.search = '';
        url.hash = '';
        const socket = new WebSocket(url.href, ['legado.' + token, 'legado.' + channel]);
        session.socket = socket;
        session.timer = setTimeout(() => fail(Error('WebSocket 连接超时，请检查原生服务是否仍在前台')), 15000);
        socket.onopen = () => {
          if (!current()) return;
          clearTimeout(session.timer);
          if (socket.protocol !== 'legado.' + channel) { fail(Error('WebSocket 子协议不匹配')); return; }
          socket.send(JSON.stringify(payload));
          callbacks.onState?.('running');
        };
        socket.onmessage = event => {
          if (!current()) return;
          try {
            if (typeof event.data !== 'string') throw Error('服务发送了非文本流');
            if (event.data.length > 8 * 1024 * 1024) throw Error('单条流消息超过 8 MiB');
            // Debug frames are the original runtime text, not JSON-wrapped or client-generated logs.
            if (channel === 'searchBook') {
              const books = JSON.parse(event.data);
              if (!Array.isArray(books) || books.some(book => !book || typeof book !== 'object' || typeof book.bookUrl !== 'string' || typeof book.origin !== 'string')) {
                throw Error('服务返回的搜索结果无效');
              }
              callbacks.onData?.(books);
            } else callbacks.onData?.(event.data);
          } catch (error) { fail(error); }
        };
        socket.onerror = () => fail(Error('WebSocket 连接失败，请检查访问密钥、前台状态和网络许可'));
        socket.onclose = event => {
          if (!current()) return;
          clearTimeout(session.timer);
          sessions.delete(channel);
          const expected = channel === 'searchBook' ? 'Search finish' : '调试结束';
          if (event.code === 1000 && event.reason === expected) callbacks.onFinish?.(event.reason);
          else callbacks.onError?.(Error('连接已关闭（' + event.code + '）' + (event.reason ? '：' + event.reason : '，操作未完成')));
        };
      } catch (error) {
        if (current() && error.name !== 'AbortError') fail(error);
      }
    }
    return {info, start, cancel, cancelAll};
  }
  return {create};
})();
