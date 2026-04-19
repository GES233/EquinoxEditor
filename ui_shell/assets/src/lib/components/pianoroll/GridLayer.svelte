<script lang="ts">
  let { viewport } = $props();

  // Draw background grid lines using CSS repeating linear gradients
  // We want vertical lines on every beat (480 ticks) or fraction depending on zoom
  let gridStyle = $derived.by(() => {
    let beatWidth = 480 * viewport.zoomX;
    return `
      background-size: ${beatWidth}px ${viewport.zoomY}px;
      background-position: ${-viewport.scrollX}px ${-viewport.scrollY}px;
      background-image: 
        linear-gradient(to right, rgba(0,0,0,0.08) 1px, transparent 1px),
        linear-gradient(to bottom, rgba(0,0,0,0.05) 1px, transparent 1px);
    `;
  });
</script>

<div class="grid-layer absolute inset-0 w-full h-full pointer-events-auto z-0" style={gridStyle}>
  <!-- Highlight black keys if desired -->
</div>
