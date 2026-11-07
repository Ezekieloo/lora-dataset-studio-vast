"""CI helper, run inside the container: install an OLDER release of a free store
plugin, so the kit's plugin update (lds-patreon plugins) has something to update.

Uses the kit's own helper module for the studio API (admin token, CSRF, restart).
Prints "PICKED <id> <old version> <newest version>" once the old release runs, or
nothing when the store has no free plugin with two compatible releases. Exit 1 when
the studio refuses a step.
"""
import sys

sys.path.insert(0, '/workspace/.lds/lib')
import lds_patreon as h  # noqa: E402


def free_releases(product):
    return [r for r in product.get('releases') or []
            if not r.get('compatibility_issues')
            and (r.get('price') or {}).get('kind') == 'free'
            and not (r.get('manifest') or {}).get('requires')]


def main():
    code, catalog = h.call('GET', '/api/plugins/store/catalog', timeout=300)
    products = (catalog or {}).get('products') or []
    print('store: HTTP %s, %s, %d products' % (code, (catalog or {}).get('status'), len(products)))
    pick = None
    for product in products:
        versions = ['%s(%s%s)' % ((r.get('manifest') or {}).get('version'), (r.get('price') or {}).get('kind'),
                                  ', incompatible' if r.get('compatibility_issues') else '')
                    for r in product.get('releases') or []]
        print('  %s: %s' % (product.get('id'), ' '.join(versions)))
        free = free_releases(product)
        if pick is None and len(free) >= 2:
            pick = product['id'], free[1]['manifest']['version'], free[0]['manifest']['version']
    if pick is None:
        return 0
    pid, old, new = pick
    print('installing %s %s (newest %s)' % pick)
    csrf = h.csrf_token()
    if csrf is None:
        return 1
    code, plan = h.call('POST', '/api/plugins/store/plan', csrf, timeout=300, body={'id': pid, 'version': old})
    if code != 200 or not isinstance(plan, dict):
        print('plan refused (HTTP %s): %s' % (code, h.reason(plan)))
        return 1
    code, prepared = h.call('POST', '/api/plugins/store/install', csrf, timeout=1800,
                            body={'id': pid, 'version': old, 'plan_id': plan.get('plan_id')})
    if code != 200:
        print('install refused (HTTP %s): %s' % (code, h.reason(prepared)))
        return 1
    code, applied = h.call('POST', '/api/plugins/apply', csrf, timeout=120)
    if code != 200 or not (applied or {}).get('restarting'):
        print('apply refused (HTTP %s): %s' % (code, h.reason(applied)))
        return 1
    if not h.wait_for_restart():
        return 1
    state = h.plugins_state() or {}
    running = next((p.get('installed_version') for p in state.get('plugins') or [] if p.get('id') == pid), None)
    if running != old:
        print('after the restart %s is %s, not %s' % (pid, running, old))
        return 1
    print('PICKED %s %s %s' % pick)
    return 0


if __name__ == '__main__':
    sys.exit(main())
