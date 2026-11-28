import { createRoot } from 'react-dom/client'
import NanospotDemo from './nanospot'

// The page keeps a screenshot in the mount until this runs, so the demo
// still shows with scripting off.
for (const mount of document.querySelectorAll<HTMLElement>('[data-nanospot-demo]')) {
  mount.replaceChildren()
  createRoot(mount).render(<NanospotDemo />)
}
