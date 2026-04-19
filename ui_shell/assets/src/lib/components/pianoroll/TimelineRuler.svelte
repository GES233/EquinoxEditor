<script lang="ts">
  let { viewport, tempos = $bindable([{tick: 0, bpm: 120}]) } = $props();
  let canvas: HTMLCanvasElement;
  
  let currentBpm = $derived.by(() => {
    if (!tempos || tempos.length === 0) return 120;
    // Find the active tempo at the current scroll position
    const currentTick = viewport.scrollX / viewport.zoomX;
    let activeTempo = tempos[0];
    for (let i = 1; i < tempos.length; i++) {
      if (tempos[i].tick <= currentTick) {
        activeTempo = tempos[i];
      } else {
        break;
      }
    }
    return activeTempo.bpm;
  });

  $effect(() => {
    if (!canvas || viewport.width === 0) return;
    
    const dpr = window.devicePixelRatio || 1;
    canvas.width = viewport.width * dpr;
    canvas.height = 30 * dpr;
    
    const ctx = canvas.getContext('2d');
    if (!ctx) return;
    ctx.scale(dpr, dpr);
    ctx.clearRect(0, 0, viewport.width, 30);
    
    const ticksPerBeat = 480; // Standard MIDI PPQ (Pulses Per Quarter Note)
    const pxPerBeat = ticksPerBeat * viewport.zoomX;
    
    // Determine grid interval based on zoom level to prevent crowding
    let beatInterval = 1;
    if (pxPerBeat < 10) beatInterval = 16; // 4 measures
    else if (pxPerBeat < 20) beatInterval = 4; // 1 measure
    else if (pxPerBeat < 40) beatInterval = 2; // half measure
    
    const startBeat = Math.floor(viewport.scrollX / (ticksPerBeat * viewport.zoomX) / beatInterval) * beatInterval;
    const endBeat = Math.ceil((viewport.scrollX + viewport.width) / (ticksPerBeat * viewport.zoomX));
    
    ctx.fillStyle = '#4a5568';
    ctx.font = '10px sans-serif';
    ctx.textBaseline = 'top';
    
    for (let i = startBeat; i <= endBeat; i += beatInterval) {
      const x = viewport.timeToPixel(i * ticksPerBeat);
      const isMeasure = i % 4 === 0;
      
      ctx.beginPath();
      ctx.moveTo(x, isMeasure ? 0 : 15);
      ctx.lineTo(x, 30);
      ctx.strokeStyle = isMeasure ? '#a0aec0' : '#e2e8f0';
      ctx.stroke();
      
      if (isMeasure) {
        ctx.fillText(`${Math.floor(i/4) + 1}.1`, x + 4, 4);
      } else if (beatInterval <= 1) {
        ctx.fillText(`.${(i%4) + 1}`, x + 4, 16);
      }
    }

    // Draw Tempo Markers
    if (tempos) {
      ctx.fillStyle = '#8b5cf6'; // violet-500
      ctx.font = '9px sans-serif';
      for (const tempo of tempos) {
        const x = viewport.timeToPixel(tempo.tick);
        if (x >= -50 && x <= viewport.width) {
          ctx.beginPath();
          ctx.moveTo(x, 0);
          ctx.lineTo(x + 5, 8);
          ctx.lineTo(x, 16);
          ctx.fill();
          ctx.fillText(`${tempo.bpm} BPM`, x + 6, 2);
        }
      }
    }
  });

  function handleMousedown(e: MouseEvent) {
    e.preventDefault();
    const startX = e.clientX;
    const startY = e.clientY;
    const startScrollX = viewport.scrollX;
    const startZoomX = viewport.zoomX;
    const rect = (e.currentTarget as HTMLElement).getBoundingClientRect();
    const timeAtCenter = (startX - rect.left + startScrollX) / startZoomX;

    let mode = 'unknown';
    const dragThreshold = 5;

    function handleMousemove(ev: MouseEvent) {
      const dx = ev.clientX - startX;
      const dy = ev.clientY - startY;
      const dist = Math.sqrt(dx * dx + dy * dy);

      if (mode === 'unknown') {
        if (dist > dragThreshold) {
          let angle = Math.abs(Math.atan2(dy, dx) * 180 / Math.PI);
          if (angle > 90) angle = 180 - angle;

          if (angle < 30) mode = 'pan'; // Mostly horizontal -> lock to pan
          else if (angle > 60) mode = 'zoom'; // Mostly vertical -> lock to zoom
          else mode = 'both'; // Diagonal -> allow both
        } else {
          return;
        }
      }

      let effectiveDx = mode === 'zoom' ? 0 : dx;
      let effectiveDy = mode === 'pan' ? 0 : dy;
      
      const zoomFactor = Math.pow(1.01, effectiveDy);
      viewport.zoomX = Math.max(viewport.MIN_ZOOM_X, Math.min(viewport.MAX_ZOOM_X, startZoomX * zoomFactor));
      
      const newScrollX = timeAtCenter * viewport.zoomX - (startX - rect.left) - effectiveDx;
      viewport.scrollX = Math.max(0, newScrollX);
    }

    function handleMouseup() {
      window.removeEventListener('mousemove', handleMousemove);
      window.removeEventListener('mouseup', handleMouseup);
    }

    window.addEventListener('mousemove', handleMousemove);
    window.addEventListener('mouseup', handleMouseup);
  }
</script>

<div class="relative w-full h-7.5 bg-slate-50 border-b border-slate-300 cursor-ew-resize overflow-hidden" onmousedown={handleMousedown} role="slider" tabindex="-1" aria-label="Timeline Ruler" aria-valuenow={currentBpm}>
  <canvas bind:this={canvas} class="w-full h-7.5"></canvas>
  <div class="absolute right-2 top-1.5 text-[11px] text-violet-600 bg-violet-50/90 border border-violet-200 px-1.5 py-0.5 rounded shadow-sm pointer-events-none">BPM: {currentBpm}</div>
</div>
