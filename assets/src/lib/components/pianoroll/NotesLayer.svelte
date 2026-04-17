<script lang="ts">
  let { viewport, notes = $bindable() } = $props();

  let visibleNotes = $derived(
    notes.filter((note: any) => {
      // Backend uses start_tick and length_tick
      const startTick = note.start_tick || 0;
      const lengthTick = note.length_tick || 480;
      const endTick = startTick + lengthTick;
      
      const noteStartX = viewport.timeToPixel(startTick);
      const noteEndX = viewport.timeToPixel(endTick);
      return noteEndX >= 0 && noteStartX <= viewport.width;
    })
  );

  let activeNoteId: string | null = $state(null);
  let dragMode: 'move' | 'resize' | null = $state(null); // 'move' | 'resize'
  let startX = $state(0);
  let startY = $state(0);
  let initialNoteState: any = $state(null);

  function updateNote(id: string, updates: any) {
    notes = notes.map((n: any) => n.id === id ? { ...n, ...updates } : n);
  }

  function handleDragStart(e: MouseEvent, note: any, mode: 'move' | 'resize' = 'move') {
    e.stopPropagation();
    activeNoteId = note.id;
    dragMode = mode;
    startX = e.clientX;
    startY = e.clientY;
    initialNoteState = { ...note };

    window.addEventListener('mousemove', handleDragMove);
    window.addEventListener('mouseup', handleDragEnd);
  }

  function handleDragMove(e: MouseEvent) {
    if (!activeNoteId || !initialNoteState) return;

    const dx = e.clientX - startX;
    const dy = e.clientY - startY;

    if (dragMode === 'move') {
      const dt = dx / viewport.zoomX;
      const dpitch = Math.round(-dy / viewport.zoomY); // invert y for pitch

      const newStartTick = Math.max(0, initialNoteState.start_tick + dt);
      const newPitch = Math.max(0, Math.min(127, initialNoteState.pitch + dpitch));

      updateNote(activeNoteId, {
        start_tick: newStartTick,
        pitch: newPitch
      });
    } else if (dragMode === 'resize') {
      const dt = dx / viewport.zoomX;
      const newDuration = Math.max(10, initialNoteState.length_tick + dt); // min 10 ticks

      updateNote(activeNoteId, {
        length_tick: newDuration
      });
    }
  }

  function handleDragEnd() {
    activeNoteId = null;
    dragMode = null;
    initialNoteState = null;
    window.removeEventListener('mousemove', handleDragMove);
    window.removeEventListener('mouseup', handleDragEnd);
  }

  function handleNoteDoubleClick(e: MouseEvent, note: any) {
    e.stopPropagation();
    // Delete note on double click for now
    notes = notes.filter((n: any) => n.id !== note.id);
  }

  function handleLyricClick(e: MouseEvent, note: any) {
    e.stopPropagation();
    const newLyric = prompt("Enter lyric:", note.lyric || "la");
    if (newLyric !== null) {
      updateNote(note.id, { lyric: newLyric });
    }
  }
</script>

<div class="absolute inset-0 w-full h-full pointer-events-none">
  {#each visibleNotes as note (note.id || `${note.start_tick}-${note.pitch}`)}
    <div
      class="absolute bg-blue-400/80 border border-blue-500 rounded-sm pointer-events-auto cursor-pointer shadow-[0_1px_2px_rgba(0,0,0,0.1)] flex items-center px-1 box-border overflow-hidden select-none hover:bg-blue-400 {activeNoteId === note.id ? 'border-white shadow-[0_0_0_2px_rgb(59,130,246)] z-10' : ''}"
      style="
        left: {viewport.timeToPixel(note.start_tick || 0)}px;
        top: {viewport.pitchToPixel(note.pitch)}px;
        width: {Math.max(1, viewport.timeToPixel((note.start_tick || 0) + (note.length_tick || 480)) - viewport.timeToPixel(note.start_tick || 0))}px;
        height: {viewport.zoomY - 2}px;
      "
      onmousedown={(e) => handleDragStart(e, note, 'move')}
      ondblclick={(e) => handleNoteDoubleClick(e, note)}
      role="button"
      tabindex="0"
    >
      <button class="text-[10px] text-white whitespace-nowrap truncate overflow-hidden bg-transparent border-none p-0 cursor-text text-left w-full" onclick={(e) => handleLyricClick(e, note)}>{note.lyric || ""}</button>
      <!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
      <div class="absolute right-0 top-0 w-1.5 h-full cursor-ew-resize bg-transparent hover:bg-white/30" onmousedown={(e) => handleDragStart(e, note, 'resize')} role="separator" tabindex="-1"></div>
    </div>
  {/each}
</div>
