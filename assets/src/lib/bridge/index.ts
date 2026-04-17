import { mount, unmount } from "svelte";

export interface EquinoxBridge {
  root: HTMLElement;
  pushEvent<T>(name: string, payload: T): void;
  handleEvent<T>(name: string, handler: (payload: T) => void): () => void;
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
          this.pushEvent(name, payload);
        },
        handleEvent: (name, handler) => {
          this.handleEvent(name, handler);
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