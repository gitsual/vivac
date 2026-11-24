// When a popup opened by hover closes again: the rule lib\Hover.psm1 keeps
// for the WPF panels and the Arch panels keep in their kit, with the same
// numbers. No clock in here: every call is given "now" in milliseconds.
//
//   button left, popup never entered   closes 500 ms later
//   popup left                         closes 350 ms later
//   back into the popup, or resting on the button again   cancels the close
//   a click or a key in the popup      pins it (only Esc or blur close it)
export const LEFT_BUTTON_MS = 500;
export const LEFT_PANEL_MS = 350;

export function createHoverClose() {
  let pinned = false;
  let inside = false;
  let deadline = null;
  return {
    get pinned() { return pinned; },
    buttonRested() { deadline = null; },
    buttonLeft(now) {
      // The pointer may already be in the popup when this is noticed.
      if (!pinned && !inside && deadline === null) deadline = now + LEFT_BUTTON_MS;
    },
    pointerIn() { inside = true; deadline = null; },
    pointerOut(now) {
      inside = false;
      if (!pinned) deadline = now + LEFT_PANEL_MS;
    },
    pin() { pinned = true; deadline = null; },
    due(now) { return !pinned && deadline !== null && now >= deadline; },
  };
}
