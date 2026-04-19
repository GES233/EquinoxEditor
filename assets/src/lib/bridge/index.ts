import { mount, unmount } from "svelte";

export interface EquinoxBridge {
  root: HTMLElement;
  pushEvent<T>(name: string, payload: T): void;
  handleEvent<T>(name: string, handler: (payload: T) => void): () => void;
}

// --- Data Types from Backend (project.ex, track.ex, segment.ex, note.ex) ---

export interface ProjectData {
  id: string;
  name: string;
  version: number;
  tempo_map: TempoPoint[];
  ticks_per_beat: number;
  tracks: Record<string, TrackData>;
  arranger_graph?: Record<string, any> | null;
  extra: Record<string, any>;
}

export interface TempoPoint {
  tick: number;
  bpm: number;
}

export interface EditorContextData {
  track_id: string | null;
  segment_id: string | null;
  scope: EditorScope;
}

export type EditorScope = "track" | "segment" | "track_synth" | "project_mix";

export interface TrackData {
  id: string;
  project_id: string | null;
  type: string;
  name: string;
  topology_ref: string | null;
  synth_graph?: Record<string, any> | null;
  color: string;
  gain: number;
  pan: number;
  mute: boolean;
  solo: boolean;
  insert_fx_chain: Record<string, any>[];
  ui_state: Record<string, any>;
  parameters: Record<string, any>;
  segments: Record<string, SegmentData>;
  extra: Record<string, any>;
}

export interface SegmentData {
  id: string;
  track_id: string | null;
  name: string;
  offset_tick: number;
  notes: NoteData[];
  curves: Record<string, any>;
  synth_override?: Record<string, any> | null;
  extra: Record<string, any>;
}

export interface NoteData {
  id: string;
  start_tick: number;
  duration_tick: number;
  key: number;
  lyric: string;
  phoneme: string | null;
  extra: Record<string, any>;
}

// Map DOM elements to mounted instances so we can destroy them
const instances = new Map<HTMLElement, Record<string, any>>();

export const createSvelteHook = (Component: any) => {
  return {
    mounted(this: any) {
      // Setup the LiveBridge implementation
      const bridge: EquinoxBridge = {
        root: this.el,
        pushEvent: (name, payload) => {
          this.pushEventTo(this.el, name, payload);
        },
        handleEvent: (name, handler) => {
          this.handleEvent(name, handler);
          this.handleEvent(`${this.el.id}:${name}`, handler);
          return () => {};
        }
      };

      const props = { bridge };

      // Mount Svelte 5 component
      const instance = mount(Component, {
        target: this.el,
        props: props
      });

      instances.set(this.el, instance);
    },
    
    destroyed(this: any) {
      const instance = instances.get(this.el);
      if (instance) {
        unmount(instance);
        instances.delete(this.el);
      }
    }
  };
};
