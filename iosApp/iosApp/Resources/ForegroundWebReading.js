'use strict';
window.LegadoWebReading = (() => {
  const el = id => document.getElementById(id);
  const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
  const defaults = {
    theme: 0, font: 0, fontSize: 18, readWidth: 800, infiniteLoading: false,
    customFontName: '', jumpDuration: 1000, spacing: {paragraph: 1, line: 0.8, letter: 0}
  };
  const themes = [
    ['纸色', '#ede7da', '#292720'], ['白色', '#ffffff', '#202329'], ['护眼', '#dce9df', '#24352a'],
    ['灰色', '#e4e6e9', '#282b30'], ['浅粉', '#f5e4e4', '#38282b'], ['浅蓝', '#e1eaf2', '#283541'],
    ['夜间', '#202124', '#d8d9dc']
  ];
  const fonts = [
    '"Microsoft YaHei", "PingFang SC", "Helvetica Neue", sans-serif',
    '"PingFang SC", -apple-system, Simsun, serif', 'Kaiti, "Kaiti SC", STKaiti, serif'
  ];
  const limits = {fontSize: [12, 48], readWidth: [320, 1600], jumpDuration: [0, 5000], paragraph: [0, 4], line: [0, 3], letter: [0, 0.3]};
  const parameter = book => '?url=' + encodeURIComponent(book.bookUrl) + (book.origin ? '&origin=' + encodeURIComponent(book.origin) : '');
  const finite = (value, fallback, [minimum, maximum]) => typeof value === 'number' && Number.isFinite(value) ? Math.max(minimum, Math.min(maximum, value)) : fallback;
  const isImageBook = book => Number.isSafeInteger(book?.type) && (book.type === 2 || (book.type & 64) !== 0);
  const progressPosition = (book, node) => Number(isImageBook(book) ? node.dataset.imagePosition : node.dataset.position);
  function normalize(value) {
    const config = {...defaults, ...value, spacing: {...defaults.spacing, ...(object(value?.spacing) ? value.spacing : {})}};
    for (const key of ['fontSize', 'readWidth', 'jumpDuration']) config[key] = finite(config[key], defaults[key], limits[key]);
    for (const key of ['paragraph', 'line', 'letter']) config.spacing[key] = finite(config.spacing[key], defaults.spacing[key], limits[key]);
    config.theme = Number.isInteger(config.theme) && themes[config.theme] ? config.theme : 0;
    config.font = Number.isInteger(config.font) && config.font >= -1 && config.font < fonts.length ? config.font : 0;
    config.infiniteLoading = config.infiniteLoading === true;
    config.customFontName = typeof config.customFontName === 'string' ? config.customFontName.slice(0, 200) : '';
    return config;
  }
  function imageSource(tag) {
    const value = tag.match(/\s+src\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/i);
    if (!value) return null;
    return (value[1] ?? value[2] ?? value[3]).replace(/&(?:amp|quot|apos|lt|gt|#\d+|#x[\da-f]+);/gi, entity => {
      const named = {'&amp;': '&', '&quot;': '"', '&apos;': "'", '&lt;': '<', '&gt;': '>'};
      if (named[entity.toLowerCase()]) return named[entity.toLowerCase()];
      const hex = entity[2].toLowerCase() === 'x';
      const code = Number.parseInt(entity.slice(hex ? 3 : 2, -1), hex ? 16 : 10);
      return code > 0 && code <= 0x10ffff && !(code >= 0xd800 && code <= 0xdfff) ? String.fromCodePoint(code) : entity;
    });
  }
  function rasterType(bytes) {
    const prefix = Array.from(bytes.subarray(0, 12), byte => String.fromCharCode(byte)).join('');
    if (bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return 'image/jpeg';
    if (bytes[0] === 0x89 && prefix.slice(1, 4) === 'PNG') return 'image/png';
    if (prefix.startsWith('GIF87a') || prefix.startsWith('GIF89a')) return 'image/gif';
    if (prefix.startsWith('RIFF') && prefix.slice(8, 12) === 'WEBP') return 'image/webp';
    if (prefix.startsWith('BM')) return 'image/bmp';
    if (prefix.slice(4, 8) === 'ftyp' && ['avif', 'avis'].includes(prefix.slice(8, 12))) return 'image/avif';
    throw Error('服务未返回支持的位图图片');
  }

  function create({request, run, onChange, onShelfChanged}) {
    let book = null, preview = false, chapters = [], selected = '', generation = 0, controller = null;
    let allowsWrites = false, active = false, pending = false, pdfURL = null, pdfLoading = false, openingBook = false;
    let pdfPageCount = 0, pdfIndex = 0, pdfRevision = 0, pdfPageURL = null, pdfPageController = null;
    let pdfDownloadLoading = false, pdfDownloadRevision = 0, pdfDownloadController = null, pdfResizeObserver = null;
    let config = normalize({}), configLoaded = false, configLoading = false, configSaving = false, configDirty = false, configRevision = 0;
    let configGeneration = 0, configController = null;
    let loaded = [], imageCount = 0, imageBytes = 0, imageWorkers = 0, imageQueue = [], animation = 0, observer = null, appendFailed = false;
    let coverURL = null, progressSaving = false, bookSaving = false, scrollFrame = 0;
    const imageURLs = new Map();
    const content = el('content');
    const current = id => active && generation === id && !controller?.signal.aborted;
    const parsed = value => typeof value === 'string' ? JSON.parse(value) : value;
    const note = text => { el('reader-note').textContent = text; };
    const configNote = text => { el('config-status').textContent = text; };

    function setPermissions(value) { allowsWrites = value === true; renderControls(); }
    function renderControls() {
      const isPDF = !!book && /\.pdf(?:$|[?#])/i.test(book.bookUrl);
      el('reading-panel').hidden = !active || !book;
      el('chapters').hidden = isPDF || !chapters.length;
      el('chapter-tools').hidden = isPDF || !chapters.length;
      el('reader-title').textContent = book?.name || '';
      el('reader-meta').textContent = book ? [book.author, book.originName, preview ? '搜索预览' : ''].filter(Boolean).join(' · ') : '';
      el('reader-intro').textContent = book?.intro || '';
      el('reader-intro').hidden = !book?.intro;
      el('reader-add').hidden = !preview;
      el('reader-add').disabled = !allowsWrites || bookSaving || openingBook;
      el('reader-progress').hidden = preview || isPDF;
      el('reader-progress').disabled = !allowsWrites || !loaded.length || progressSaving || pending;
      el('reader-retry').disabled = openingBook || pending || pdfLoading;
      const position = chapters.findIndex(chapter => String(chapter.index) === selected);
      el('chapter-previous').disabled = pending || position <= 0;
      el('chapter-next').disabled = pending || position < 0 || position >= chapters.length - 1;
      el('chapters').disabled = pending;
      el('config-fields').disabled = !configLoaded || configSaving || configLoading;
      el('config-save').disabled = !allowsWrites || !configLoaded || configLoading || configSaving;
      el('config-reload').disabled = configLoading || configSaving;
      el('config-custom-font').hidden = config.font !== -1;
      el('pdf-panel').hidden = !isPDF;
      el('pdf-retry').disabled = pdfLoading;
      el('pdf-previous').disabled = pdfLoading || pdfPageCount === 0 || pdfIndex <= 0;
      el('pdf-next').disabled = pdfLoading || pdfPageCount === 0 || pdfIndex >= pdfPageCount - 1;
      el('pdf-page-number').disabled = pdfLoading || pdfPageCount === 0;
      el('pdf-page-number').value = String(pdfIndex + 1);
      el('pdf-page-number').max = String(Math.max(1,pdfPageCount));
      el('pdf-page-count').textContent = '/ ' + pdfPageCount + ' 页';
      el('pdf-fetch-download').disabled = pdfDownloadLoading || !!pdfURL;
      el('reader-more').hidden = !config.infiniteLoading || !loaded.length || isPDF;
      el('reader-more').disabled = pending || !nextLoadedChapter();
      el('reader-more').textContent = appendFailed ? '重试加载下一章' : '加载下一章';
    }
    function fillConfig() {
      for (const key of ['font', 'fontSize', 'readWidth', 'customFontName', 'jumpDuration']) el('config-' + key).value = String(config[key]);
      for (const key of ['paragraph', 'line', 'letter']) el('config-' + key).value = String(config.spacing[key]);
      el('config-infiniteLoading').checked = config.infiniteLoading;
      for (const button of el('config-themes').children) button.setAttribute('aria-pressed', String(Number(button.dataset.theme) === config.theme));
      renderControls();
    }
    function applyConfig() {
      const [, background, foreground] = themes[config.theme];
      content.style.backgroundColor = background;
      content.style.color = foreground;
      content.style.fontFamily = config.font === -1 ? '"' + config.customFontName.replace(/["\\\r\n]/g, '') + '", serif' : fonts[config.font];
      content.style.fontSize = config.fontSize + 'px';
      content.style.maxWidth = config.readWidth + 'px';
      content.style.setProperty('--reader-line', String(1 + config.spacing.line));
      content.style.setProperty('--reader-paragraph', config.spacing.paragraph + 'em');
      content.style.setProperty('--reader-letter', config.spacing.letter + 'em');
      observeMore(); renderControls();
    }
    async function loadConfig(force = false) {
      if (configLoading || (!force && configLoaded)) return;
      if (force && configDirty && !confirm('重新读取将丢弃未保存的 Web 阅读配置。继续？')) return;
      const id = configGeneration, revision = ++configRevision;
      configController?.abort();configController = new AbortController();
      configLoading = true; configNote('正在读取…'); renderControls();
      try {
        const raw = await request('/getReadConfig', undefined, {signal: configController.signal});
        if (id !== configGeneration || revision !== configRevision) return;
        let value = {};
        if (raw !== null && raw !== undefined && raw !== '') value = parsed(raw);
        if (!object(value)) throw Error('Web 阅读配置不是 JSON 对象');
        config = normalize(value); configLoaded = true; configDirty = false;
        fillConfig(); applyConfig(); configNote(raw === null || raw === undefined || raw === '' ? '尚未保存 Web 配置' : '已读取 Web 配置');
      } catch (error) {
        if (id !== configGeneration || revision !== configRevision || error.name === 'AbortError') return;
        if (error.message === '没有配置') {
          config = normalize({}); configLoaded = true; configDirty = false;
          fillConfig(); applyConfig(); configNote('尚未保存 Web 配置');
        } else { configNote('读取失败：' + error.message); throw error; }
      } finally {
        if (revision === configRevision) { configLoading = false; renderControls(); }
      }
    }
    async function saveConfig() {
      if (!allowsWrites || !configLoaded || configSaving) return;
      const value = structuredClone(config), revision = configRevision, id = configGeneration;
      configController?.abort();configController = new AbortController();
      configSaving = true; configNote('正在保存…'); renderControls();
      try {
        await request('/saveReadConfig', value, {signal: configController.signal});
        if (id !== configGeneration || revision !== configRevision) return;
        configDirty = false; configNote('已保存 Web 阅读配置');
      } catch (error) {
        if (id === configGeneration && error.name !== 'AbortError') { configNote('保存失败：' + error.message); throw error; }
      } finally { if(id === configGeneration) { configSaving = false; renderControls(); } }
    }
    function editConfig(key, value) {
      if (!configLoaded || configSaving || configLoading) return;
      if (['paragraph', 'line', 'letter'].includes(key)) config.spacing[key] = finite(Number(value), defaults.spacing[key], limits[key]);
      else if (['fontSize', 'readWidth', 'jumpDuration'].includes(key)) config[key] = finite(Number(value), defaults[key], limits[key]);
      else config[key] = value;
      configDirty = true; configRevision++; configNote('未保存'); fillConfig(); applyConfig();
    }
    function releaseImages() {
      imageQueue = []; imageWorkers = 0; imageCount = 0;
      for (const url of imageURLs.keys()) URL.revokeObjectURL(url);
      imageURLs.clear();
      imageBytes = 0;
    }
    function releaseImage(url) {
      const value = imageURLs.get(url);
      if (!value) return;
      imageBytes -= value.size;URL.revokeObjectURL(url);imageURLs.delete(url);
    }
    function trimOldestChapter() {
      if (loaded.length < 6) return;
      const removed = loaded.shift().section, anchor = loaded[0]?.section;
      const previousTop = anchor?.getBoundingClientRect().top;
      imageQueue = imageQueue.filter(job => !removed.contains(job.figure));
      imageCount = Math.max(0,imageCount - removed.querySelectorAll('figure[data-queued]').length);
      for (const [url, value] of imageURLs) if (removed.contains(value.figure)) releaseImage(url);
      removed.remove();
      if(selected === removed.dataset.chapter && loaded[0]){selected = String(loaded[0].index);el('chapters').value = selected;}
      if (anchor && previousTop !== undefined) window.scrollBy(0,anchor.getBoundingClientRect().top - previousTop);
    }
    function clearPDFPage() {
      pdfRevision++;pdfPageController?.abort();pdfPageController = null;
      pdfResizeObserver?.disconnect();pdfResizeObserver = null;
      el('pdf-page-image').removeAttribute('src');
      el('pdf-text-layer').replaceChildren();el('pdf-page').hidden = true;
      if(pdfPageURL)URL.revokeObjectURL(pdfPageURL);
      pdfPageURL = null;
    }
    function clearPDF() {
      clearPDFPage();pdfPageCount = 0;pdfIndex = 0;
      pdfDownloadRevision++;pdfDownloadController?.abort();pdfDownloadController = null;pdfDownloadLoading = false;
      el('pdf-download').removeAttribute('href'); el('pdf-download').hidden = true;
      el('pdf-download-status').textContent = '';
      if (pdfURL) URL.revokeObjectURL(pdfURL);
      pdfURL = null;
    }
    function resetContent() {
      observer?.disconnect(); observer = null; cancelAnimationFrame(animation);
      cancelAnimationFrame(scrollFrame);scrollFrame = 0;
      controller?.abort(); controller = new AbortController();
      generation++;
      pending = false; progressSaving = false; bookSaving = false; pdfLoading = false;appendFailed = false;
      releaseImages(); clearPDF(); content.replaceChildren(); loaded = [];
      el('reader-more-status').textContent = '';
    }
    function leave() {
      resetContent(); controller.abort(); active = false; book = null; chapters = []; selected = '';openingBook = false;
      if (coverURL) URL.revokeObjectURL(coverURL);
      coverURL = null;el('cover').removeAttribute('src');el('cover').hidden = true;
      configGeneration++;configRevision++;configController?.abort();configLoading = false;configSaving = false;
      el('chapters').replaceChildren(); note(''); renderControls(); onChange?.();
    }
    function resetSession() {
      leave(); config = normalize({}); configLoaded = false; configDirty = false;
      allowsWrites = false; configNote(''); fillConfig(); applyConfig();
    }
    function render(show) {
      el('reading-panel').hidden = !show || !active || !book;
      renderControls();
    }
    function chapterOptions() {
      el('chapters').replaceChildren();
      for (const chapter of chapters) {
        const option = document.createElement('option');
        option.value = String(chapter.index); option.textContent = chapter.title || '第 ' + (Number(chapter.index) + 1) + ' 章';
        el('chapters').append(option);
      }
      el('chapters').value = selected;
    }
    async function open(value, options = {}) {
      leave();controller = new AbortController(); active = true; book = structuredClone(value); preview = options.preview === true;openingBook = true;
      const id = generation, signal = controller.signal;
      note('正在读取…'); renderControls(); onChange?.();
      // Config and cover failures do not prevent reading the book itself.
      void run(() => loadConfig(), () => current(id));
      try {
        if(preview) {
          const details = parsed(await request('/getBookInfo' + parameter(book), undefined, {signal}));
          if(!current(id))return;
          if(!object(details)||typeof details.bookUrl!=='string'||!details.bookUrl||typeof details.name!=='string')throw Error('服务返回的书籍详情无效');
          book = structuredClone(details);renderControls();onChange?.();
        }
        void loadCover(book, id, signal);
        if (/\.pdf(?:$|[?#])/i.test(book.bookUrl)) { await loadPDF(); return; }
        const value = parsed(await request('/getChapterList' + parameter(book), undefined, {signal}));
        if (!current(id)) return;
        if (!Array.isArray(value) || value.some(chapter => !object(chapter) || !Number.isSafeInteger(chapter.index) || chapter.index < 0)) throw Error('目录格式无效');
        chapters = value;
        const saved = chapters.find(chapter => chapter.index === book.durChapterIndex) || chapters[0];
        selected = saved ? String(saved.index) : '';
        chapterOptions(); renderControls();
        if (saved) await openChapter(false, true); else note('目录为空');
      } catch (error) {
        if (current(id) && error.name !== 'AbortError') { note('读取失败：' + error.message); throw error; }
      } finally { if(current(id)){openingBook = false;renderControls();} }
    }
    function bitmap(value) {
      if (typeof value !== 'string' || !value || value.length > Math.ceil(16 * 1024 * 1024 / 3) * 4) throw Error('图片为空或超过 16 MiB');
      const base64 = value.replace(/^data:image\/[a-z0-9.+-]+;base64,/i, '').replace(/\s/g, '');
      const raw = atob(base64), bytes = Uint8Array.from(raw, character => character.charCodeAt(0));
      if (bytes.length > 16 * 1024 * 1024) throw Error('图片超过 16 MiB');
      return {bytes, type: rasterType(bytes)};
    }
    async function loadCover(target, id, signal) {
      try {
        const value = await request('/cover' + parameter(target), undefined, {signal});
        if (!current(id) || !value) return;
        const image = bitmap(value);
        coverURL = URL.createObjectURL(new Blob([image.bytes], {type: image.type}));
        el('cover').src = coverURL; el('cover').alt = target.name || ''; el('cover').hidden = false;
      } catch (error) { if (current(id) && error.name !== 'AbortError') el('cover').hidden = true; }
    }
    async function loadPDF() {
      if (!book) return;
      const id = generation, target = book;
      clearPDFPage();const revision = pdfRevision;
      pdfPageController = new AbortController();
      pdfLoading = true;note('正在读取 PDF 页数…');renderControls();
      try {
        const info = parsed(await request('/getPDFInfo' + parameter(target), undefined, {signal:pdfPageController.signal}));
        if (!current(id) || book !== target || revision !== pdfRevision) return;
        if(!object(info) || !Number.isSafeInteger(info.pageCount) || info.pageCount <= 0)throw Error('PDF 没有可显示的页面');
        pdfPageCount = info.pageCount;pdfIndex = Math.min(pdfIndex,pdfPageCount - 1);
        await loadPDFPage(pdfIndex);
      } catch (error) {
        if (current(id) && book === target && revision === pdfRevision && error.name !== 'AbortError') { note('PDF 读取失败：' + error.message); throw error; }
      } finally { if (current(id) && revision === pdfRevision) { pdfLoading = false;renderControls(); } }
    }
    function fitPDFText() {
      const layer = el('pdf-text-layer'), box = layer.getBoundingClientRect();
      if(!box.width || !box.height)return;
      const lines = [...layer.children];
      for(const line of lines){line.style.fontSize = Number(line.dataset.height) * box.height + 'px';line.firstElementChild.style.transform = 'none';}
      const scales = lines.map(line => {
        const actual = line.firstElementChild.getBoundingClientRect().width;
        return actual > 0 ? Number(line.dataset.width) * box.width / actual : 1;
      });
      lines.forEach((line,index)=>{line.firstElementChild.style.transform = 'scaleX(' + scales[index] + ')';});
    }
    function buildPDFText(lines) {
      const fragment = document.createDocumentFragment();
      for(const value of lines){
        if(!value.text || !value.width || !value.height)continue;
        const line = document.createElement('div'), text = document.createElement('span');
        line.className = 'pdf-text-line';line.dataset.height = String(value.height);line.dataset.width = String(value.width);
        line.style.left = value.left * 100 + '%';line.style.top = value.top * 100 + '%';
        line.style.width = value.width * 100 + '%';line.style.height = value.height * 100 + '%';
        text.textContent = value.text;line.append(text);fragment.append(line);
      }
      el('pdf-text-layer').replaceChildren(fragment);
    }
    function validatePDFPage(value,index) {
      if(!object(value) || value.index !== index || !Number.isFinite(value.width) || !Number.isFinite(value.height)
        || value.width <= 0 || value.height <= 0 || value.width * value.height > 4000000)throw Error('PDF 原页尺寸无效或超过 4 MP');
      if(!Array.isArray(value.text) || value.text.length > 10000)throw Error('PDF 文字层无效或行数过多');
      let textSize = 0;
      for(const line of value.text){
        if(!object(line) || typeof line.text !== 'string')throw Error('PDF 文字行无效');
        textSize += line.text.length;
        if(textSize > 1024 * 1024 || ['left','top','width','height'].some(key=>typeof line[key] !== 'number' || !Number.isFinite(line[key]) || line[key] < 0 || line[key] > 1))throw Error('PDF 文字层超出范围');
      }
      if(typeof value.png !== 'string' || !/^[A-Za-z0-9+/]*={0,2}$/.test(value.png))throw Error('PDF 原页不是纯 base64 PNG');
      const image = bitmap(value.png), bytes = image.bytes;
      if(image.type !== 'image/png' || bytes.length < 24 || String.fromCharCode(...bytes.subarray(12,16)) !== 'IHDR')throw Error('PDF 原页不是 PNG');
      const header = new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength), width = header.getUint32(16), height = header.getUint32(20);
      if(!width || !height || width * height > 4000000 || Math.abs(width - value.width) > 1 || Math.abs(height - value.height) > 1)throw Error('PDF PNG 尺寸与原页不匹配或超过 4 MP');
      return image;
    }
    async function loadPDFPage(index) {
      if(!book || !Number.isSafeInteger(index) || index < 0 || index >= pdfPageCount)return;
      const id = generation, target = book;
      clearPDFPage();const revision = pdfRevision;
      pdfPageController = new AbortController();pdfIndex = index;pdfLoading = true;
      note('正在读取第 ' + (index + 1) + ' 页…');renderControls();
      const owns = () => current(id) && book === target && revision === pdfRevision;
      try{
        const value = parsed(await request('/bookPDFPage' + parameter(target) + '&index=' + index,undefined,{signal:pdfPageController.signal}));
        if(!owns())return;
        const image = validatePDFPage(value,index);
        pdfPageURL = URL.createObjectURL(new Blob([image.bytes],{type:'image/png'}));
        const page = el('pdf-page'), img = el('pdf-page-image');
        page.style.maxWidth = value.width + 'px';page.style.aspectRatio = value.width + ' / ' + value.height;
        page.setAttribute('aria-label','PDF 第 ' + (index + 1) + ' 页');
        img.src = pdfPageURL;await img.decode();
        if(!owns())return;
        buildPDFText(value.text);page.hidden = false;fitPDFText();
        pdfResizeObserver = new ResizeObserver(()=>{if(owns())fitPDFText();});pdfResizeObserver.observe(page);
        note('');
      }catch(error){
        if(owns() && error.name !== 'AbortError'){
          el('pdf-page-image').removeAttribute('src');el('pdf-text-layer').replaceChildren();el('pdf-page').hidden = true;
          if(pdfPageURL)URL.revokeObjectURL(pdfPageURL);pdfPageURL = null;
          note('PDF 第 ' + (index + 1) + ' 页读取失败：' + error.message);throw error;
        }
      }finally{if(owns()){pdfLoading = false;renderControls();}}
    }
    async function preparePDFDownload() {
      if(!book || pdfDownloadLoading || pdfURL)return;
      const id = generation, target = book, revision = ++pdfDownloadRevision;
      pdfDownloadController?.abort();pdfDownloadController = new AbortController();pdfDownloadLoading = true;
      el('pdf-download-status').textContent = '正在获取原文件…';renderControls();
      const owns = () => current(id) && book === target && revision === pdfDownloadRevision;
      try{
        const blob = await request('/bookPDF' + parameter(target),undefined,{signal:pdfDownloadController.signal,format:'pdf'});
        if(!owns())return;
        if(!(blob instanceof Blob) || blob.type.split(';')[0] !== 'application/pdf' || blob.size > 16 * 1024 * 1024)throw Error('PDF 格式无效或超过 16 MiB');
        pdfURL = URL.createObjectURL(blob);
        el('pdf-download').href = pdfURL;el('pdf-download').download = (target.name || 'book') + '.pdf';el('pdf-download').hidden = false;
        el('pdf-download-status').textContent = '';
      }catch(error){if(owns() && error.name !== 'AbortError'){el('pdf-download-status').textContent = '获取失败：' + error.message;throw error;}}
      finally{if(owns()){pdfDownloadLoading = false;renderControls();}}
    }
    function nextLoadedChapter() {
      const last = loaded[loaded.length - 1];
      if (!last) return null;
      const position = chapters.findIndex(chapter => chapter.index === last.index);
      return chapters[position + 1] || null;
    }
    function enqueueImage(src, figure, id, signal) {
      if (!src || src.length > 16384) { figure.textContent = '图片地址无效'; return; }
      if (imageCount >= 128) { figure.textContent = '当前阅读页已达到 128 张图片上限'; return; }
      imageCount++;
      figure.dataset.queued = 'true';
      imageQueue.push({src, figure, id, signal, target: book});
      pumpImages(id);
    }
    function pumpImages(id) {
      while (current(id) && imageWorkers < 3 && imageQueue.length) {
        const job = imageQueue.shift(); imageWorkers++;
        void loadImage(job).finally(() => {
          if (!current(id)) return;
          imageWorkers--; pumpImages(id);
        });
      }
    }
    async function loadImage({src, figure, id, signal, target}) {
      try {
        const value = await request('/bookImage' + parameter(target) + '&src=' + encodeURIComponent(src), undefined, {signal});
        if (!current(id) || !figure.isConnected) return;
        const image = bitmap(value);
        if (imageBytes + image.bytes.length > 64 * 1024 * 1024) throw Error('当前阅读页图片超过 64 MiB，请切换章节');
        imageBytes += image.bytes.length;
        const url = URL.createObjectURL(new Blob([image.bytes], {type: image.type}));
        imageURLs.set(url,{figure,size:image.bytes.length});
        const img = document.createElement('img');
        img.alt = '正文图片'; img.decoding = 'async';
        img.onload = () => {
          if (!current(id)) return;
          if (img.naturalWidth * img.naturalHeight > 32 * 1024 * 1024) {
            img.removeAttribute('src'); figure.textContent = '图片尺寸过大'; releaseImage(url);
          }
        };
        img.onerror = () => {
          if (!current(id)) return;
          figure.textContent = '图片解码失败'; releaseImage(url);
        };
        img.src = url; figure.replaceChildren(img);
      } catch (error) {
        if (!current(id) || error.name === 'AbortError') return;
        figure.replaceChildren();
        const text = document.createElement('span'), retry = document.createElement('button');
        text.textContent = '图片读取失败：' + error.message; retry.textContent = '重试';
        retry.onclick = () => { retry.disabled = true; figure.textContent = '正在读取图片…'; imageQueue.push({src, figure, id, signal, target}); pumpImages(id); };
        figure.append(text, retry);
      }
    }
    function appendText(section, text, index, offset) {
      let position = offset;
      for (const line of text.split('\n')) {
        if (line.trim()) {
          const paragraph = document.createElement('p');
          paragraph.textContent = line; paragraph.dataset.chapter = String(index); paragraph.dataset.position = String(position);
          section.append(paragraph);
        }
        position += line.length + 1;
      }
    }
    function buildChapter(chapter, data, id, signal) {
      const section = document.createElement('section'), heading = document.createElement('h2');
      section.className = 'reader-chapter'; section.dataset.chapter = String(chapter.index); section.dataset.position = '0';
      heading.textContent = data.title || chapter.title || '';heading.dataset.chapter = String(chapter.index);heading.dataset.position = '0';section.append(heading);
      const text = data.content;
      if (text.length > 8 * 1024 * 1024) throw Error('章节正文超过 8 MiB');
      if (text.split('\n', 20002).length > 20000) throw Error('章节段落过多');
      let cursor = 0;
      const images = [];
      // Only recognize image placeholders; all other source markup remains literal text.
      for (const match of text.matchAll(/<img\b[^>]{0,16384}>/gi)) {
        appendText(section, text.slice(cursor, match.index), chapter.index, cursor);
        const figure = document.createElement('figure');
        figure.dataset.chapter = String(chapter.index); figure.dataset.position = String(match.index); figure.textContent = '正在读取图片…';
        figure.dataset.imagePosition = String(images.length);
        section.append(figure); images.push([imageSource(match[0]), figure]); cursor = match.index + match[0].length;
      }
      appendText(section, text.slice(cursor), chapter.index, cursor);
      content.append(section);
      for (const [src, figure] of images) enqueueImage(src, figure, id, signal);
      return section;
    }
    async function openChapter(append = false, restore = false) {
      if (!book || selected === '' || pending) return;
      const chapter = append ? nextLoadedChapter() : chapters.find(value => String(value.index) === selected);
      if (!chapter) return;
      if (!append && loaded.length) {
        // Keep the active book and configuration, but invalidate chapter/image callbacks together.
        resetContent(); chapterOptions();
      }
      const id = generation, signal = controller.signal;
      pending = true; note('正在读取正文…'); renderControls();
      try {
        const value = await request('/getBookContent' + parameter(book) + '&index=' + encodeURIComponent(chapter.index), undefined, {signal});
        if (!current(id)) return;
        const data = parsed(value);
        if (!object(data) || typeof data.content !== 'string') throw Error('服务返回的正文格式无效');
        if(append)trimOldestChapter();
        const section = buildChapter(chapter, data, id, signal);
        loaded.push({index: chapter.index, section});
        appendFailed = false;
        note(''); applyConfig();
        if (!append && !restore) jump(section);
        if (!append && restore && Number.isSafeInteger(book.durChapterPos) && book.durChapterPos > 0) {
          const candidates = [...section.querySelectorAll(isImageBook(book) ? 'figure[data-image-position]' : '[data-position]')];
          const target = candidates.find(node => progressPosition(book, node) >= book.durChapterPos) || candidates[candidates.length - 1];
          if (target) jump(target, 0);
        }
      } catch (error) {
        if (current(id) && error.name !== 'AbortError') { if(append)appendFailed = true;note('正文读取失败：' + error.message); throw error; }
      } finally {
        if (current(id)) { pending = false; renderControls(); observeMore(); }
      }
    }
    function jump(target, duration = config.jumpDuration) {
      cancelAnimationFrame(animation);
      if (!duration || matchMedia('(prefers-reduced-motion: reduce)').matches) { target.scrollIntoView({block: 'start', behavior: 'instant'}); return; }
      const start = window.scrollY, end = target.getBoundingClientRect().top + start - 16, time = performance.now(), id = generation;
      const step = now => {
        if (!current(id)) return;
        const portion = Math.min(1, (now - time) / duration), eased = 1 - Math.pow(1 - portion, 3);
        window.scrollTo(0, start + (end - start) * eased);
        if (portion < 1) animation = requestAnimationFrame(step);
      };
      animation = requestAnimationFrame(step);
    }
    function observeMore() {
      observer?.disconnect(); observer = null;
      if (!active || !config.infiniteLoading || pending || appendFailed || !nextLoadedChapter()) return;
      observer = new IntersectionObserver(entries => {
        if (entries.some(entry => entry.isIntersecting) && !pending) void run(() => openChapter(true));
      }, {rootMargin: '0px 0px 160px 0px'});
      observer.observe(el('reader-more'));
    }
    function visiblePosition() {
      const markers = [...content.querySelectorAll(isImageBook(book) ? 'figure[data-image-position]' : 'p[data-position],figure[data-position],h2[data-position]')];
      return markers.find(node => node.getBoundingClientRect().bottom > 16 && node.getBoundingClientRect().top < window.innerHeight)
        || markers[0];
    }
    async function saveProgress() {
      if (!book || preview || !allowsWrites || progressSaving || !loaded.length) return;
      const target = visiblePosition();
      if (!target) return;
      const index = Number(target.dataset.chapter), position = progressPosition(book, target);
      const chapter = chapters.find(value => value.index === index), id = generation, targetBook = book;
      const value = {bookUrl: book.bookUrl, name: book.name, author: book.author || '', durChapterIndex: index, durChapterPos: position, durChapterTitle: chapter?.title || '', durChapterTime: Date.now()};
      progressSaving = true; renderControls(); note('正在保存进度…');
      try {
        await request('/saveBookProgress', value, {signal: controller.signal});
        if (!current(id) || book !== targetBook) return;
        Object.assign(book, value); note('已保存当前进度'); onShelfChanged?.();
      } catch (error) { if (current(id) && error.name !== 'AbortError') { note('保存失败：' + error.message); throw error; } }
      finally { if (current(id)) { progressSaving = false; renderControls(); } }
    }
    async function addBook() {
      if (!book || !preview || !allowsWrites || bookSaving || openingBook) return;
      const id = generation, target = book; bookSaving = true; renderControls();
      try {
        const saved = await request('/saveBook', target, {signal: controller.signal});
        if (!current(id) || book !== target) return;
        if(object(saved)&&typeof saved.bookUrl==='string'&&saved.bookUrl===book.bookUrl)book = {...book,...saved};
        preview = false; note('已加入书架'); onShelfChanged?.();
      } catch (error) { if (current(id) && error.name !== 'AbortError') { note('加入书架失败：' + error.message); throw error; } }
      finally { if (current(id)) { bookSaving = false; renderControls(); } }
    }
    for (let index = 0; index < themes.length; index++) {
      const [name, background, foreground] = themes[index], button = document.createElement('button');
      button.type = 'button'; button.className = 'theme-swatch'; button.dataset.theme = String(index);
      button.style.backgroundColor = background; button.style.color = foreground;
      button.setAttribute('aria-label', name); button.title = name;
      button.onclick = () => editConfig('theme', index); el('config-themes').append(button);
    }
    for (const key of ['fontSize', 'readWidth', 'jumpDuration', 'customFontName', 'paragraph', 'line', 'letter']) {
      el('config-' + key).onchange = event => editConfig(key, event.target.value);
    }
    el('config-font').onchange = event => editConfig('font', Number(event.target.value));
    el('config-infiniteLoading').onchange = event => editConfig('infiniteLoading', event.target.checked);
    el('config-save').onclick = () => run(saveConfig);
    el('config-reload').onclick = () => run(() => loadConfig(true));
    el('chapters').onchange = () => { selected = el('chapters').value; run(() => openChapter()); };
    function adjacent(delta) {
      const marker = visiblePosition(), from = marker ? String(marker.dataset.chapter) : selected;
      const position = chapters.findIndex(chapter => String(chapter.index) === from), target = chapters[position + delta];
      if (!target) return;
      selected = String(target.index); chapterOptions(); run(() => openChapter());
    }
    el('chapter-previous').onclick = () => adjacent(-1);
    el('chapter-next').onclick = () => adjacent(1);
    el('reader-more').onclick = () => run(() => openChapter(true));
    el('reader-progress').onclick = () => run(saveProgress);
    el('reader-add').onclick = () => run(addBook);
    el('reader-retry').onclick = () => {if(book){const target = structuredClone(book), options = {preview};run(()=>open(target,options));}};
    el('pdf-retry').onclick = () => run(()=>pdfPageCount ? loadPDFPage(pdfIndex) : loadPDF());
    el('pdf-previous').onclick = () => run(()=>loadPDFPage(pdfIndex - 1));
    el('pdf-next').onclick = () => run(()=>loadPDFPage(pdfIndex + 1));
    el('pdf-page-number').onchange = () => {
      const value = Number(el('pdf-page-number').value);
      if(!Number.isSafeInteger(value) || value < 1 || value > pdfPageCount){note('页码应在 1 到 ' + pdfPageCount + ' 之间');renderControls();return;}
      run(()=>loadPDFPage(value - 1));
    };
    el('pdf-fetch-download').onclick = () => run(preparePDFDownload);
    el('reader-close').onclick = leave;
    window.addEventListener('scroll', () => {
      if(!active || pending || scrollFrame)return;
      scrollFrame = requestAnimationFrame(() => {
        scrollFrame = 0;
        const marker = visiblePosition();
        if(marker && marker.dataset.chapter !== selected){selected = marker.dataset.chapter;el('chapters').value = selected;renderControls();}
      });
    }, {passive:true});
    fillConfig(); applyConfig();
    return {open, leave, render, resetSession, setPermissions, get book() { return book; }, isDirty: () => configDirty};
  }
  return {create};
})();
