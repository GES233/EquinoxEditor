<script lang="ts">
  let { viewport, grid } = $props();

  // Draw background grid lines using CSS repeating linear gradients
  // We want vertical lines on every beat (480 ticks) or fraction depending on zoom
  // Grid 开启时叠加最小单位（quantum）细分线
  let gridStyle = $derived.by(() => {
    let beatWidth = 480 * viewport.zoomX;

    const images = [
      `linear-gradient(to right, rgba(0,0,0,0.08) 1px, transparent 1px)`,
      `linear-gradient(to bottom, rgba(0,0,0,0.05) 1px, transparent 1px)`,
    ];
    const sizes = [`${beatWidth}px ${viewport.zoomY}px`];

    if (grid.enabled && grid.quantum > 0 && grid.quantum < 480) {
      images.unshift(`linear-gradient(to right, rgba(0,0,0,0.04) 1px, transparent 1px)`);
      sizes.unshift(`${grid.quantum * viewport.zoomX}px ${viewport.zoomY}px`);
    }

    return `
      background-size: ${sizes.join(", ")};
      background-position: ${-viewport.scrollX}px ${-viewport.scrollY}px;
      background-image: ${images.join(", ")};
    `;
  });
</script>

<div class="grid-layer absolute inset-0 w-full h-full pointer-events-auto z-0" style={gridStyle}>
  <!-- Highlight black keys if desired -->
</div>
