import { createRoot } from 'react-dom/client'
import FloodlightDemo from './floodlight'

// The page keeps a screenshot in the mount until this runs, so the demo
// still shows with scripting off.
for (const mount of document.querySelectorAll<HTMLElement>('[data-floodlight-demo]')) {
  mount.replaceChildren()
  createRoot(mount).render(<FloodlightDemo />)
}
