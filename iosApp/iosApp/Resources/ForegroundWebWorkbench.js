'use strict';
window.LegadoWebWorkbench = (() => {
  const byId = id => document.getElementById(id);
  function create({streams, run, openPreview, getDraft, getMode, isWriting}) {
    let revision = 0, searchRunning = false, searchCapped = false, resultFrame = 0, resultSize = 0, capReason = '';
    const results = new Map();
    const resultSizes = new Map();
    const debug = {sources: {running: false, text: '', target: '', status: ''}, rss: {running: false, text: '', target: '', status: ''}};
    const channelFor = mode => mode === 'rss' ? 'rssSourceDebug' : 'bookSourceDebug';
    const setSearchStatus = text => { byId('search-status').textContent = text; };

    function searchControls() {
      byId('search-start').disabled = searchRunning;
      byId('search-stop').disabled = !searchRunning;
    }
    function showResults() {
      const query = byId('search-filter').value.trim().toLocaleLowerCase();
      const list = byId('search-results');
      list.replaceChildren();
      let count = 0;
      for (const book of results.values()) {
        if (query && ![book.name, book.author, book.originName, book.origin].join(' ').toLocaleLowerCase().includes(query)) continue;
        count++;
        const row = document.createElement('div'), button = document.createElement('button');
        const title = document.createElement('strong'), subtitle = document.createElement('small');
        row.className = 'search-result';
        button.className = 'search-preview';
        title.textContent = book.name || book.bookUrl;
        subtitle.textContent = [book.author, book.originName || book.origin, book.latestChapterTitle].filter(Boolean).join(' · ');
        button.append(title, subtitle);
        button.onclick = () => run(() => openPreview(book));
        row.append(button);
        list.append(row);
      }
      byId('search-count').textContent = count + ' / ' + results.size + ' 本';
    }
    async function search() {
      const key = byId('search-key').value.trim(), scope = byId('search-scope').value.trim();
      if (!key) throw Error('搜索内容不能为空');
      if (key.length > 2048 || scope.length > 8192) throw Error('搜索条件过长');
      streams.cancel('searchBook');
      const id = ++revision;
      results.clear();resultSizes.clear();resultSize = 0; searchRunning = true; searchCapped = false;
      showResults(); searchControls(); setSearchStatus('正在连接…');
      await streams.start('searchBook', {key, ...(scope ? {scope} : {})}, {
        onState: state => { if (id === revision) setSearchStatus(state === 'running' ? '搜索中…' : '正在连接…'); },
        onData: books => {
          if (id !== revision || getMode() !== 'search') return;
          for (const book of books) {
            if (!book.bookUrl || !book.origin) continue;
            const identity = JSON.stringify([book.origin, book.bookUrl]);
            if (!results.has(identity) && results.size >= 2000) { searchCapped = true;capReason = '已显示 2000 本';break; }
            const size = JSON.stringify(book).length * 2;
            const nextSize = resultSize - (resultSizes.get(identity) || 0) + size;
            if(nextSize > 16 * 1024 * 1024){searchCapped = true;capReason = '搜索结果达到 16 MiB 上限';break;}
            resultSize = nextSize;resultSizes.set(identity,size);
            results.set(identity, book);
          }
          if(!resultFrame)resultFrame=requestAnimationFrame(()=>{resultFrame=0;if(id===revision)showResults()});
          if (searchCapped) {
            streams.cancel('searchBook'); searchRunning = false; searchControls();
            setSearchStatus(capReason + '，搜索已停止；可缩小书源范围继续搜索');
          }
        },
        onFinish: reason => {
          if (id !== revision) return;
          searchRunning = false; searchControls();
          setSearchStatus(reason + ' · ' + results.size + ' 本');
        },
        onError: error => {
          if (id !== revision) return;
          searchRunning = false; searchControls(); setSearchStatus(error.message);
        }
      });
    }
    function stopSearch() {
      revision++; streams.cancel('searchBook'); searchRunning = false;
      searchControls(); setSearchStatus('已取消 · 保留 ' + results.size + ' 本结果');
    }
    function renderDebug() {
      const mode = getMode(), enabled = mode === 'sources' || mode === 'rss';
      byId('debug-panel').hidden = !enabled || !getDraft(false);
      if (!enabled) return;
      const state = debug[mode];
      byId('debug-heading').textContent = mode === 'rss' ? 'RSS 调试' : '书源调试';
      byId('debug-key-label').hidden = mode === 'rss';
      byId('debug-target').textContent = state.target;
      byId('debug-target').hidden = !state.target;
      byId('debug-status').textContent = state.status;
      byId('debug-start').disabled = state.running || isWriting();
      byId('debug-stop').disabled = !state.running;
      byId('debug-output').textContent = state.text;
    }
    async function startDebug() {
      const mode = getMode();
      if (!(mode in debug)) return;
      const draft = getDraft(true), tag = mode === 'rss' ? draft.sourceUrl : draft.bookSourceUrl;
      const key = byId('debug-key').value.trim();
      if (!tag) throw Error('请选择已保存的源');
      if (mode === 'sources' && !key) throw Error('请输入调试关键词、详情地址或目录地址');
      if (key.length > 8192) throw Error('调试参数过长');
      const state = debug[mode], channel = channelFor(mode), id = ++revision;
      streams.cancel(channel); state.text = ''; state.running = true;state.target = tag;
      state.status = '正在连接…'; renderDebug();
      await streams.start(channel, mode === 'rss' ? {tag} : {tag, key}, {
        onState: value => { if (id === revision) {state.status = value === 'running' ? '调试中…' : '正在连接…';byId('debug-status').textContent = state.status;} },
        onData: text => {
          if (id !== revision || getMode() !== mode) return;
          if (state.text.length + text.length > 1024 * 1024) {
            streams.cancel(channel); state.running = false;
            state.status = '日志超过 1 MiB，调试已停止'; renderDebug(); return;
          }
          state.text += text + (text.endsWith('\n') ? '' : '\n');
          const output = byId('debug-output'), atBottom = output.scrollHeight - output.scrollTop - output.clientHeight < 40;
          output.textContent = state.text;
          if (atBottom) output.scrollTop = output.scrollHeight;
        },
        onFinish: reason => { if (id === revision) { state.running = false;state.status = reason;renderDebug(); } },
        onError: error => { if (id === revision) { state.running = false;state.status = error.message;renderDebug(); } }
      });
    }
    function stopDebug() {
      const mode = getMode();
      if (!(mode in debug) || !debug[mode].running) return;
      revision++; streams.cancel(channelFor(mode)); debug[mode].running = false;
      debug[mode].status = '已取消'; renderDebug();
    }
    function leave() {
      cancelAnimationFrame(resultFrame);resultFrame=0;
      revision++; streams.cancelAll(); searchRunning = false;
      for (const state of Object.values(debug)) {if(state.running)state.status = '已取消';state.running = false;}
      searchControls(); renderDebug();
    }
    function render() {
      byId('search-panel').hidden = getMode() !== 'search';
      renderDebug(); searchControls();
    }
    byId('search-form').onsubmit = event => { event.preventDefault(); run(search); };
    byId('search-stop').onclick = stopSearch;
    byId('search-filter').oninput = showResults;
    byId('debug-start').onclick = () => run(startDebug);
    byId('debug-stop').onclick = stopDebug;
    byId('debug-clear').onclick = () => {
      const state = debug[getMode()];
      if (state) { state.text = ''; renderDebug(); }
    };
    return {render, leave, search, cancelDebug: stopDebug, isBusy: () => searchRunning || Object.values(debug).some(state => state.running)};
  }
  return {create};
})();
