<script lang="ts">
  let { viewport } = $props();
  
  const PITCHES = Array.from({length: 128}, (_, i) => 127 - i);
  const noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"];
  
  function getNoteInfo(pitch: number) {
    const octave = Math.floor(pitch / 12) - 1; // MIDI standard: 60 is C4
    const noteIdx = pitch % 12;
    const isBlack = [1, 3, 6, 8, 10].includes(noteIdx);
    const name = noteNames[noteIdx] + octave;
    return { isBlack, name, isC: noteIdx === 0 };
  }

  function handleMousedown(e: MouseEvent) {
    e.preventDefault();
    const startX = e.clientX;
    const startY = e.clientY;
    const startScrollY = viewport.scrollY;
    const startZoomY = viewport.zoomY;
    const rect = (e.currentTarget as HTMLElement).getBoundingClientRect();
    const pitchAtCenter = viewport.MAX_PITCH - (startY - rect.top + startScrollY) / startZoomY;

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

          if (angle > 60) mode = 'pan'; // Mostly vertical -> lock to pan
          else if (angle < 30) mode = 'zoom'; // Mostly horizontal -> lock to zoom
          else mode = 'both'; // Diagonal -> allow both
        } else {
          return;
        }
      }

      let effectiveDx = mode === 'pan' ? 0 : dx;
      let effectiveDy = mode === 'zoom' ? 0 : dy;

      const zoomFactor = Math.pow(1.01, effectiveDx);
      viewport.zoomY = Math.max(viewport.MIN_ZOOM_Y, Math.min(viewport.MAX_ZOOM_Y, startZoomY * zoomFactor));
      
      const newScrollY = (viewport.MAX_PITCH - pitchAtCenter) * viewport.zoomY - (startY - rect.top) - effectiveDy;
      viewport.scrollY = Math.max(0, Math.min(newScrollY, viewport.MAX_PITCH * viewport.zoomY - viewport.height));
    }

    function handleMouseup() {
      window.removeEventListener('mousemove', handleMousemove);
      window.removeEventListener('mouseup', handleMouseup);
    }

    window.addEventListener('mousemove', handleMousemove);
    window.addEventListener('mouseup', handleMouseup);
  }
</script>

<div class="relative w-full h-full bg-white border-r border-slate-300 overflow-hidden cursor-ns-resize" onmousedown={handleMousedown} role="slider" tabindex="-1" aria-label="Piano Keys" aria-valuenow={0}>
  <div class="absolute top-0 left-0 w-full" style="transform: translateY({-viewport.scrollY}px);">
    {#each PITCHES as pitch}
      {@const info = getNoteInfo(pitch)}
      <div
        class="box-border border-b border-slate-200 flex items-center justify-end pr-1 {info.isBlack ? 'bg-slate-100' : 'bg-white'}"
        style="height: {viewport.zoomY}px;"
      >
        {#if info.isC || viewport.zoomY > 15}
          <span class="text-[10px] text-gray-500 select-none">{info.name}</span>
        {/if}
      </div>
    {/each}
  </div>
</div>
