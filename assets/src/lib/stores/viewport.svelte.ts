export class Viewport {
  scrollX = $state(0);
  scrollY = $state(0);
  zoomX = $state(0.1); // pixels per tick
  zoomY = $state(20); // pixels per semitone (wider keys)

  // Canvas bounds (should be updated by the component)
  width = $state(0);
  height = $state(0);

  // Constants
  MIN_ZOOM_X = 0.005;
  MAX_ZOOM_X = 5;
  MIN_ZOOM_Y = 5;
  MAX_ZOOM_Y = 50;
  MIN_PITCH = 0;
  MAX_PITCH = 127;

  timeToPixel(time: number) {
    return time * this.zoomX - this.scrollX;
  }

  pixelToTime(px: number) {
    return (px + this.scrollX) / this.zoomX;
  }

  pitchToPixel(pitch: number) {
    // 0 is top of screen, so we invert the pitch
    return (this.MAX_PITCH - pitch) * this.zoomY - this.scrollY;
  }

  pixelToPitch(py: number) {
    return this.MAX_PITCH - (py + this.scrollY) / this.zoomY;
  }

  pan(dx: number, dy: number) {
    this.scrollX = Math.max(0, this.scrollX + dx);
    this.scrollY = Math.max(
      0,
      Math.min(
        this.scrollY + dy,
        this.MAX_PITCH * this.zoomY - this.height
      )
    );
  }

  zoom(factorX: number, factorY: number, centerX: number, centerY: number) {
    const timeAtCenter = this.pixelToTime(centerX);
    const pitchAtCenter = this.pixelToPitch(centerY);

    this.zoomX = Math.max(this.MIN_ZOOM_X, Math.min(this.MAX_ZOOM_X, this.zoomX * factorX));
    this.zoomY = Math.max(this.MIN_ZOOM_Y, Math.min(this.MAX_ZOOM_Y, this.zoomY * factorY));

    this.scrollX = Math.max(0, timeAtCenter * this.zoomX - centerX);
    // Don't change scrollY on Y zoom for now to keep things simple, or adjust if needed
    // this.scrollY = ... 
  }
}
