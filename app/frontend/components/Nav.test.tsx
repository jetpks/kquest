import { render, screen } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import type { ReactNode } from 'react'
import type { SharedProps } from '@/types'

// The house pattern (Dashboard/Index.test.tsx): usePage returns this object
// by reference, so per-test shared props are written into it before render.
const props: SharedProps = { current_user: null, flash: {} }

vi.mock('@inertiajs/react', () => ({
  Link: ({ children }: { children?: ReactNode }) => <a>{children}</a>,
  router: { delete: vi.fn() },
  usePage: () => ({ props: { ...props } }),
}))

import Nav from './Nav'

function renderNav(shared: Partial<SharedProps> = {}) {
  props.current_user = shared.current_user ?? null
  props.flash = shared.flash ?? {}
  props.oauth_providers = shared.oauth_providers
  return render(<Nav />)
}

// The Nav's sign-in door(s): one native form POST per enabled provider
// (shared props; absent = the github-only default). The developer door is
// dev-only config — when OAUTH_PROVIDERS omits it, the button must not
// render.
describe('Nav sign-in doors', () => {
  it('renders the GitHub door by default (no providers prop)', () => {
    renderNav()
    expect(screen.getByRole('button', { name: /sign in with github/i })).toBeTruthy()
    expect(screen.queryByRole('button', { name: /dev sign-in/i })).toBeNull()
  })

  it('renders the dev door alongside GitHub when developer is enabled', () => {
    renderNav({ oauth_providers: ['github', 'developer'] })
    const github = screen.getByRole('button', { name: /sign in with github/i }).closest('form')
    const dev = screen.getByRole('button', { name: /dev sign-in/i }).closest('form')
    expect(github?.getAttribute('action')).toBe('/auth/github')
    expect(dev?.getAttribute('action')).toBe('/auth/developer')
    // The dev door carries the same CSRF bridge as the GitHub door.
    expect(dev?.querySelector('input[name="_csrf_token"]')).toBeTruthy()
  })

  it('renders no sign-in doors for a signed-in user', () => {
    renderNav({ current_user: { id: 1, username: 'octocat', avatar_url: null } })
    expect(screen.queryByRole('button', { name: /sign in/i })).toBeNull()
    expect(screen.getByText('octocat')).toBeTruthy()
  })
})
