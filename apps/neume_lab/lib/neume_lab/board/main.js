// NeumeLab.Board 前端：钢琴卷帘 + 冲突横幅 + 渲染任务/试听。
// 无外部依赖：canvas 绘制、WebAudio 播放 WAV（{:binary, info, buffer} 事件）。

export function init(ctx, data) {
  const state = {
    projectId: data.project_id,
    snapshot: data.snapshot,
    jobs: data.jobs || [],
    voicebanks: data.voicebanks || [],
    check: null,
    selected: null,
    status: null,
    playing: null,
  };

  ctx.root.innerHTML = `
    <style>
      .lab { font: 13px/1.5 system-ui, sans-serif; color: #d7dce2; display: flex; flex-direction: column; gap: 8px; }
      .lab button { background: #2b6cb0; color: #fff; border: 0; border-radius: 4px; padding: 3px 10px; cursor: pointer; font-size: 12px; }
      .lab button:hover { background: #3182ce; }
      .lab input { background: #12141a; color: #d7dce2; border: 1px solid #3a4150; border-radius: 4px; padding: 2px 6px; font-size: 12px; }
      .lab-toolbar { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
      .lab-toolbar .sep { width: 1px; height: 18px; background: #3a4150; }
      .lab .status { font-size: 12px; }
      .lab .status.error { color: #fc8181; }
      .lab .status.info { color: #68d391; }
      .lab .muted { color: #8b93a1; }
      .lab .banner { background: #4a2b2b; border: 1px solid #9b3a3a; border-radius: 6px; padding: 8px 10px; }
      .lab .banner.hidden { display: none; }
      .lab .banner-title { font-weight: 600; margin-bottom: 4px; color: #feb2b2; }
      .lab .banner .entry { display: flex; align-items: center; gap: 8px; padding: 2px 0; }
      .lab .banner code { background: rgba(0,0,0,0.35); padding: 1px 5px; border-radius: 3px; }
      .lab .legend { display: flex; gap: 12px; font-size: 12px; }
      .lab .legend .swatch { display: inline-block; width: 10px; height: 10px; border-radius: 2px; margin-right: 4px; }
      .lab canvas { border: 1px solid #3a4150; border-radius: 6px; max-width: 100%; }
      .lab .selected { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; background: #22262e; border-radius: 6px; padding: 6px 10px; }
      .lab .selected .tag, .lab .jobs .tag { background: #2b6cb0; border-radius: 3px; padding: 1px 6px; font-size: 11px; }
      .lab .jobs-head { font-weight: 600; }
      .lab .jobs .job { display: flex; align-items: center; gap: 10px; padding: 3px 0; border-bottom: 1px solid #262b34; }
      .lab .jobs .status-running { color: #f6ad55; }
      .lab .jobs .status-completed { color: #68d391; }
      .lab .jobs .status-failed { color: #fc8181; }
      .lab .jobs .err { color: #fc8181; font-size: 12px; }
    </style>
    <div class="lab">
      <div class="lab-toolbar">
        <button data-act="undo">撤销</button>
        <button data-act="redo">重做</button>
        <span class="sep"></span>
        <button data-act="check">检查</button>
        <span class="sep"></span>
        <label>pin <input id="lab-pin" type="number" min="0" style="width:5em"></label>
        <button data-act="render">渲染</button>
        <span id="lab-status" class="status"></span>
      </div>
      <div id="lab-banner" class="banner hidden"></div>
      <div id="lab-legend" class="legend"></div>
      <canvas id="lab-roll" width="920" height="320"></canvas>
      <div id="lab-selected" class="selected muted">未选中音符（点击卷帘中的音符）</div>
      <div class="jobs-head">渲染任务</div>
      <div id="lab-jobs" class="jobs"></div>
    </div>`;

  const el = (sel) => ctx.root.querySelector(sel);
  const canvas = el("#lab-roll");
  const g = canvas.getContext("2d");
  const esc = (s) => String(s).replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
  let audioCtx = null;
  let noteRects = [];

  function trackHue(i) { return (210 + i * 47) % 360; }

  function setStatus(status) {
    state.status = status;
    const node = el("#lab-status");
    node.className = status ? `status ${status.kind}` : "status";
    node.textContent = status ? status.text : "";
  }

  function collectNotes() {
    const notes = [];
    (state.snapshot?.tracks ?? []).forEach((t, ti) =>
      t.notes.forEach((n) => notes.push({ ...n, track_id: t.id, pins: t.pins, hue: trackHue(ti) }))
    );
    return notes;
  }

  function drawRoll() {
    const notes = collectNotes();
    g.clearRect(0, 0, canvas.width, canvas.height);
    g.fillStyle = "#16181d";
    g.fillRect(0, 0, canvas.width, canvas.height);

    const pitches = notes.map((n) => Number(n.pitch)).filter(Number.isFinite);
    const lo = pitches.length ? Math.floor(Math.min(...pitches)) - 3 : 55;
    const hi = pitches.length ? Math.ceil(Math.max(...pitches)) + 3 : 72;
    const maxTick = Math.max(1920, ...notes.map((n) => n.end_tick)) * 1.05;
    const ppt = canvas.width / maxTick;
    const pps = canvas.height / (hi - lo + 1);
    const yOf = (m) => canvas.height - (m - lo + 1) * pps;

    for (let m = lo; m <= hi; m++) {
      g.fillStyle = m % 12 === 0 ? "rgba(255,255,255,0.14)" : "rgba(255,255,255,0.05)";
      g.fillRect(0, yOf(m), canvas.width, 1);
    }
    for (let t = 0; t <= maxTick; t += 480) {
      g.fillStyle = t % 1920 === 0 ? "rgba(255,255,255,0.16)" : "rgba(255,255,255,0.05)";
      g.fillRect(Math.round(t * ppt), 0, 1, canvas.height);
    }

    noteRects = [];
    for (const n of notes) {
      const m = Number(n.pitch);
      if (!Number.isFinite(m)) continue;
      const x = n.start_tick * ppt;
      const w = Math.max((n.end_tick - n.start_tick) * ppt, 2);
      const y = yOf(m + 1);
      const h = pps;
      const isSel =
        state.selected && state.selected.note_id === n.id && state.selected.track_id === n.track_id;

      g.fillStyle = `hsl(${n.hue} 70% ${isSel ? 62 : 45}%)`;
      g.beginPath();
      g.roundRect(x + 1, y + 1, w - 2, h - 2, 3);
      g.fill();
      if (isSel) {
        g.strokeStyle = "#ffffff";
        g.lineWidth = 1.5;
        g.stroke();
      }

      if (n.lyric) {
        g.fillStyle = "rgba(255,255,255,0.92)";
        g.font = "11px sans-serif";
        g.fillText(n.lyric, x + 5, y + h / 2 + 4);
      }

      const chans = (n.pins || []).filter((p) => (p.anchor?.refs || []).includes(n.id));
      chans.forEach((p, i) => {
        const cx = x + w - 9 - i * 13;
        g.fillStyle = p.channel === "pitch" ? "#ffd166" : "#06d6a0";
        g.beginPath();
        g.arc(cx, y + 8, 4.5, 0, Math.PI * 2);
        g.fill();
        g.fillStyle = "#16181d";
        g.font = "bold 7px sans-serif";
        g.fillText(p.channel === "pitch" ? "P" : "D", cx - 2.5, y + 10.5);
      });

      noteRects.push({ x, y, w, h, track_id: n.track_id, note_id: n.id });
    }

    g.fillStyle = "rgba(255,255,255,0.5)";
    g.font = "11px sans-serif";
    g.fillText(`history pin: ${state.snapshot?.history_pin ?? "-"}`, 8, 14);
  }

  function renderLegend() {
    el("#lab-legend").innerHTML = (state.snapshot?.tracks ?? [])
      .map((t, i) => {
        const vb = t.voicebank ? "" : "（未绑声库）";
        return `<span><span class="swatch" style="background:hsl(${trackHue(i)} 70% 45%)"></span>${esc(t.name || t.id)}${vb}</span>`;
      })
      .join("");
  }

  function notePins(track, noteId) {
    return (track?.pins || []).filter((p) => (p.anchor?.refs || []).includes(noteId));
  }

  function renderSelected() {
    const box = el("#lab-selected");
    const track = state.selected && state.snapshot.tracks.find((t) => t.id === state.selected.track_id);
    const note = track && track.notes.find((n) => n.id === state.selected.note_id);
    if (!note) {
      state.selected = null;
      box.className = "selected muted";
      box.textContent = "未选中音符（点击卷帘中的音符）";
      return;
    }

    const pins = notePins(track, note.id);
    const durationPinned = pins.some((p) => p.channel === "duration");
    box.className = "selected";
    box.innerHTML = `
      <span class="tag">${esc(note.id)}</span>
      <span>[${note.start_tick}, ${note.end_tick}) · MIDI ${esc(note.pitch)}</span>
      <label>歌词 <input id="lab-lyric" value="${esc(note.lyric ?? "")}"></label>
      <button data-note-act="save">保存歌词</button>
      ${durationPinned
        ? `<button data-note-act="unmount">卸载时长 pin</button>`
        : `<button data-note-act="mount">挂时长 pin</button>`}
      ${pins.length ? `<span class="muted">${pins.map((p) => esc(p.channel)).join(" / ")} 已挂载</span>` : ""}
    `;

    box.querySelector('[data-note-act="save"]').addEventListener("click", () => {
      ctx.pushEvent("edit_lyric", {
        track_id: track.id,
        note_id: note.id,
        lyric: box.querySelector("#lab-lyric").value,
      });
    });

    const mountBtn = box.querySelector('[data-note-act="mount"]');
    if (mountBtn) {
      mountBtn.addEventListener("click", () => {
        const phonemes = note.metadata?.phonemes;
        const count = Array.isArray(phonemes) && phonemes.length ? phonemes.length : 1;
        const span = note.end_tick - note.start_tick;
        const per = Math.max(1, Math.round(span / count));
        const durations = Array.from({ length: count }, (_, i) => [i, per]);
        ctx.pushEvent("mount_duration", { track_id: track.id, note_id: note.id, durations });
      });
    }

    const unmountBtn = box.querySelector('[data-note-act="unmount"]');
    if (unmountBtn) {
      unmountBtn.addEventListener("click", () => {
        ctx.pushEvent("unmount_pin", { track_id: track.id, note_id: note.id, channel: "duration" });
      });
    }
  }

  function fmtReason(reason) {
    const s = typeof reason === "string" ? reason : JSON.stringify(reason) ?? "-";
    return s.length > 240 ? s.slice(0, 240) + "…" : s;
  }

  function renderBanner() {
    const banner = el("#lab-banner");
    if (!state.check || state.check.status !== "failed") {
      banner.className = "banner hidden";
      banner.innerHTML = "";
      return;
    }
    banner.className = "banner";
    const stale =
      state.snapshot && state.check.pin !== state.snapshot.history_pin
        ? `<div class="muted">该结果对应 pin ${esc(state.check.pin)}，当前已是 pin ${esc(state.snapshot.history_pin)}——请重新检查确认。</div>`
        : "";
    banner.innerHTML =
      `<div class="banner-title">检查发现 ${state.check.entries.length} 处冲突</div>` +
      stale +
      state.check.entries
        .map((e, i) => {
          const full = typeof e.reason === "string" ? e.reason : JSON.stringify(e.reason);
          return `
        <div class="entry" title="${esc(full)}">
          <code>${esc(e.channel)}</code><span>pin @ 音符 <code>${esc(e.note_id)}</code>：${esc(fmtReason(e.reason))}</span>
          <button data-repatch="${i}">repatch</button>
        </div>`;
        })
        .join("");
    banner.querySelectorAll("[data-repatch]").forEach((btn) =>
      btn.addEventListener("click", () => {
        const entry = state.check.entries[Number(btn.dataset.repatch)];
        // 即时反馈：证明点击与事件已发出；后续 repatch_result / check_result
        // / command_error 事件会给出终态。
        setStatus({ kind: "info", text: `repatch ${entry.note_id} 处理中…` });
        ctx.pushEvent("repatch", { track_id: entry.track_id, patch_ids: [entry.patch_id] });
      })
    );
  }

  function renderJobs() {
    const box = el("#lab-jobs");
    if (!state.jobs.length) {
      box.innerHTML = `<span class="muted">尚无渲染任务</span>`;
      return;
    }
    box.innerHTML = state.jobs
      .map(
        (j) => `
      <div class="job">
        <span class="tag">#${esc(j.job_id)}</span>
        <span>pin ${esc(j.source_pin)}</span>
        <span class="status-${esc(j.status)}">${esc(j.status)}</span>
        ${j.error ? `<span class="err">${esc(j.error)}</span>` : ""}
        ${j.status === "completed" && j.artifact_id
          ? `<button data-play="${esc(j.artifact_id)}">${state.playing === j.artifact_id ? "播放中…" : "播放"}</button>`
          : ""}
      </div>`
      )
      .join("");
    box.querySelectorAll("[data-play]").forEach((btn) =>
      btn.addEventListener("click", () => ctx.pushEvent("play", { artifact_id: btn.dataset.play }))
    );
  }

  function renderAll() {
    drawRoll();
    renderLegend();
    renderSelected();
    renderBanner();
    renderJobs();
  }

  canvas.addEventListener("click", (ev) => {
    const rect = canvas.getBoundingClientRect();
    const x = ((ev.clientX - rect.left) / rect.width) * canvas.width;
    const y = ((ev.clientY - rect.top) / rect.height) * canvas.height;
    const hit = [...noteRects].reverse().find((r) => x >= r.x && x <= r.x + r.w && y >= r.y && y <= r.y + r.h);
    state.selected = hit ? { track_id: hit.track_id, note_id: hit.note_id } : null;
    drawRoll();
    renderSelected();
  });

  ctx.root.querySelectorAll("[data-act]").forEach((btn) =>
    btn.addEventListener("click", () => {
      const act = btn.dataset.act;
      if (act === "render") {
        const v = parseInt(el("#lab-pin").value, 10);
        ctx.pushEvent("render", { pin: Number.isFinite(v) ? v : null });
      } else {
        ctx.pushEvent(act, {});
      }
    })
  );

  ctx.handleEvent("snapshot", (snapshot) => {
    state.snapshot = snapshot;
    // 不清除状态条：transient 反馈（错误/进行中/完成）不被快照刷新冲掉。
    const pinInput = el("#lab-pin");
    if (document.activeElement !== pinInput) pinInput.value = snapshot.history_pin;
    renderAll();
  });

  ctx.handleEvent("jobs", (jobs) => {
    state.jobs = jobs;
    renderJobs();
  });

  ctx.handleEvent("check_result", (result) => {
    state.check = result;
    renderBanner();
    if (result.status === "ok") setStatus({ kind: "info", text: "检查通过" });
  });

  ctx.handleEvent("repatch_result", (result) => {
    const results = result.results || [];
    const degraded = results.filter((r) => r.status === "degraded");
    const repatched = results.length - degraded.length;
    if (degraded.length) {
      setStatus({ kind: "error", text: `repatch：${repatched} 重签，${degraded.length} 降级（${fmtReason(degraded[0].reason)}）` });
    } else {
      setStatus({ kind: "info", text: `repatch 完成：${repatched} 个 pin 重签` });
    }
  });

  ctx.handleEvent("command_error", ({ op, reason }) => {
    setStatus({ kind: "error", text: `${op} 失败：${reason}` });
  });

  ctx.handleEvent("audio", ([info, buffer]) => {
    audioCtx = audioCtx || new (window.AudioContext || window.webkitAudioContext)();
    audioCtx
      .decodeAudioData(buffer.slice(0))
      .then((audioBuffer) => {
        const src = audioCtx.createBufferSource();
        src.buffer = audioBuffer;
        src.connect(audioCtx.destination);
        src.onended = () => {
          state.playing = null;
          renderJobs();
        };
        state.playing = info.artifact_id;
        renderJobs();
        src.start();
      })
      .catch((err) => setStatus({ kind: "error", text: `音频解码失败：${err}` }));
  });

  el("#lab-pin").value = data.snapshot?.history_pin ?? 0;
  renderAll();
}
