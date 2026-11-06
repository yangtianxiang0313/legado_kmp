'use strict';
window.LegadoWebUpload = (() => {
  function create({request, run, discardUpload, onShelfChanged}) {
    const el = id => document.getElementById(id);
    let pending = null, busy = false, committing = false, allowed = false, revision = 0, controller = null, uploadId = null, visible = false;
    const note = value => { el('upload-status').textContent = value; };
    function render(show = visible) {
      visible = show;
      el('upload-panel').hidden = !visible;
      el('upload-file').disabled = !allowed || busy || !!uploadId;
      el('upload-preview').disabled = !allowed || busy || !!uploadId || !el('upload-file').files.length;
      el('upload-confirm').hidden = !pending;
      el('upload-confirm').disabled = !allowed || busy;
      el('upload-cancel').disabled = !uploadId || (busy && !controller);
      el('upload-entry').disabled = busy;
      el('upload-entry-label').hidden = !pending?.entries?.length;
    }
    function newID() {
      const bytes = crypto.getRandomValues(new Uint8Array(16));
      bytes[6] = (bytes[6] & 15) | 64; bytes[8] = (bytes[8] & 63) | 128;
      const value = Array.from(bytes, byte => byte.toString(16).padStart(2, '0')).join('');
      return [value.slice(0, 8), value.slice(8, 12), value.slice(12, 16), value.slice(16, 20), value.slice(20)].join('-');
    }
    async function discard(id) { await discardUpload(id); }
    async function prepare() {
      const file = el('upload-file').files[0];
      if (!allowed || busy || uploadId || !file) return;
      if (!file.size || file.size > 32 * 1024 * 1024) throw Error('书籍文件应大于 0 且不超过 32 MiB');
      const id = ++revision;
      const target = newID(); uploadId = target;
      controller = new AbortController(); busy = true; note('正在上传…'); render();
      const form = new FormData(); form.append('fileName', file.name); form.append('fileData', file);
      try {
        const result = await request('/prepareLocalBook?uploadId=' + encodeURIComponent(target), form, {
          signal: controller.signal,
          onUploadProgress: (loaded, total) => {
            if (id === revision) note(total && loaded < total ? '正在上传 ' + Math.floor(loaded / total * 100) + '%' : '正在解析文件…');
          }
        });
        if (id !== revision) { void discard(target).catch(() => {}); return; }
        if (!result || result.uploadId !== target || typeof result.fileName !== 'string'
          || !Array.isArray(result.entries) || !result.entries.length || result.entries.length > 2000
          || result.entries.some(entry => !entry || typeof entry.path !== 'string' || !entry.path || entry.path.length > 4096 || typeof entry.name !== 'string')
          || new Set(result.entries.map(entry => entry.path)).size !== result.entries.length) throw Error('上传预览响应无效');
        pending = result; el('upload-entry').replaceChildren();
        for (const entry of result.entries) {
          const option = document.createElement('option'); option.value = entry.path; option.textContent = entry.name || entry.path;
          el('upload-entry').append(option);
        }
        note(result.fileName + ' · 待确认，尚未加入书架');
      } catch (error) {
        if (id === revision) {
          try { await discard(target); if (id === revision) uploadId = null; } catch {}
          if (id === revision && error.name !== 'AbortError') { note('上传失败：' + error.message + (uploadId ? '；请取消待清理上传' : '')); throw error; }
        }
      }
      finally { if (id === revision) { busy = false; controller = null; render(); } }
    }
    async function commit() {
      if (!allowed || busy || !pending) return;
      const id = revision, target = pending;
      controller = new AbortController();
      busy = true; committing = true; note('正在导入…'); render();
      try {
        const result = await request('/commitLocalBook', {uploadId: target.uploadId, entryPath: el('upload-entry').value}, {signal: controller.signal});
        if (id !== revision) return;
        if (result !== true) throw Error('服务未确认导入结果');
        pending = null; uploadId = null; el('upload-file').value = ''; note('已加入书架'); onShelfChanged?.();
        void discard(target.uploadId).catch(() => {});
      } catch (error) { if (id === revision) { note('导入失败：' + error.message); throw error; } }
      finally { if (id === revision) { busy = false; committing = false; controller = null; render(); } }
    }
    async function cancel() {
      const wasCommitting = committing, id = ++revision;
      controller?.abort(); controller = null;
      const target = uploadId; busy = !!target; committing = false; render();
      if (!target) { note('已取消上传'); render(); return; }
      try {
        await discard(target);
        if (id !== revision) return;
        pending = null; uploadId = null; el('upload-entry').replaceChildren();
        note(wasCommitting ? '已结束上传请求；已保存的书籍不会撤销' : '已取消，未加入书架');
        if (wasCommitting) onShelfChanged?.();
      } catch (error) { if (id === revision) { note('取消未确认：' + error.message + '；待确认文件将在 5 分钟后过期'); throw error; } }
      finally { if (id === revision) { busy = false; render(); } }
    }
    function leave() {
      const target = uploadId, wasCommitting = committing;
      ++revision; controller?.abort(); controller = null;
      pending = null; uploadId = null; busy = false; committing = false;
      el('upload-entry').replaceChildren(); note(''); render();
      if (target) void discard(target).catch(() => {});
      if (wasCommitting) onShelfChanged?.(false);
    }
    function resetSession() {
      leave(); allowed = false;
      el('upload-file').value = ''; el('upload-entry').replaceChildren(); note(''); render();
    }
    el('upload-file').onchange = () => { note(''); render(); };
    el('upload-preview').onclick = () => run(prepare);
    el('upload-confirm').onclick = () => run(commit);
    el('upload-cancel').onclick = () => run(cancel);
    render(false);
    return {render, leave, resetSession, setPermissions(value) { allowed = value === true; if (!allowed) leave(); render(); }, isDirty: () => busy || !!uploadId, isCommitting: () => committing};
  }
  return {create};
})();
