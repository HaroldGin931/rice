# Rice

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

Ready to run in production? Please [check our deployment guides](https://phoenix.hexdocs.pm/deployment.html).

## Login with Semi (OAuth 2.0 / OIDC)

Rice is a confidential OAuth client for **Semi** (`https://api.semi.im`,
Authorization Code + PKCE, S256). It performs the code→token exchange and the
userinfo lookup server-side — the browser never sees the client secret or the
Semi tokens.

- `Rice.SemiOAuth` (`lib/rice/semi_oauth.ex`) — transport: authorize URL,
  token exchange, userinfo, refresh. Endpoints resolve under the issuer.
- `RiceWeb.SemiAuthController` (`lib/rice_web/controllers/semi_auth_controller.ex`)
  — routes `GET /login`, `GET /callback`, `GET /logout`. PKCE `state` /
  `code_verifier` live in the signed Phoenix session; only the userinfo
  claims are kept after login (the long-lived Semi access token is not
  persisted in the browser cookie).

### Config (env vars, read in `config/runtime.exs`)

| Var | Required | Default |
|-----|----------|---------|
| `SEMI_CLIENT_ID` | yes | — |
| `SEMI_CLIENT_SECRET` | yes | — |
| `SEMI_REDIRECT_URI` | no | `https://rice.together.li/callback` |
| `SEMI_ISSUER` | no | `https://api.semi.im` |

The `redirect_uri` must exactly match the one registered on the Semi OAuth
app. Scopes requested: `openid profile wallet`.

Run locally against the live Semi provider:

```sh
SEMI_CLIENT_ID=semi_xxx SEMI_CLIENT_SECRET=yyy mix phx.server
# then open http://localhost:4000 — note the registered redirect_uri points at
# rice.together.li, so the full round-trip only completes on the deployed host.
```

In production the two secrets come from the `secret/xjdao` Nomad Variable
(`semi_client_id` / `semi_client_secret`), injected by
`xjdao-deploy/nomad/rice.nomad.hcl`. Deploy with `ginger deploy -c rice.yml`
from `xjdao-deploy/ginger/`.

> This is the OAuth half of a planned **identity bridge**: a later step will
> have rice mint or create an AT Protocol PDS session from the Semi identity
> and hand it to the frontend. See the deploy repo notes for the design.

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://phoenix.hexdocs.pm/overview.html
* Docs: https://phoenix.hexdocs.pm
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
