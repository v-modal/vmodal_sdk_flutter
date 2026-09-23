# Framebase user library

This Flutter example gives each signed-in user a separate street-video library.
The app owns sign-in and credential acquisition; the VMODAL SDK owns API
transport. The bundled videos, grouped search results, uploads, index jobs,
and timestamp playback follow the original `05_framebase` example.

## Run offline

From `uinterface/sdk_flutter`:

```bash
bash install.sh install
cd example/05_framebase_userlogin
flutter_bin="$(bash ../../install.sh flutter_bin)"
"$flutter_bin" pub get
"$flutter_bin" run --device-id DEVICE_ID
```

The default `MockFirebaseAuth` emits an empty response, so the app opens on
the sign-in page and makes no VMODAL requests. A fake account and queued
`VmodalCredential` responses can be injected in tests. Fixture keys are
placeholders, not live credentials. Email/password sign-in through the fake
adapter only succeeds for accounts supplied to that adapter.

## Session contract

`lib/user/` owns auth state, credential validation, permissions, token renewal,
and account transitions. A trusted app-owned credential issuer must bind a
Firebase UID to a VMODAL principal and stable `collection_user_id`, returning
an `ak_...` key accepted by the gateway. Firebase Auth does not issue that key.
No Firebase project config or issuer endpoint exists in this repo yet, so this
example does not enable a production Firebase adapter.

The controller validates expiry and binding, checks `auth.me()`, then opens
`framebase_streets__user_<collection_user_id>` with stream `street_study`.
It refreshes the VMODAL credential one minute before expiry and before SDK
operations. The VMODAL key lives in memory only. Sign-out clears the provider,
stops work, closes the client, and removes the previous account from the UI.
The gateway remains the authorization boundary; UI permissions only hide
unavailable actions.

Imported MP4s and the `archive.json` manifest are stored under
`accounts/<collection_user_id>/` in application support. Search results,
downloaded images, signed URLs, and credentials are never persisted. Firebase's
native session may be restored by a future real adapter, but the VMODAL key
must be reacquired after each process start.

## Verify

```bash
"$flutter_bin" pub get
"$(bash ../../install.sh dart_bin)" format --output=none --set-exit-if-changed lib test
"$flutter_bin" analyze
"$flutter_bin" test
```

The offline tests cover auth states, scopes, refresh, account switching,
archive separation, result mapping, and UI gating. Device testing with two
real accounts, a trusted issuer, and a gateway-accepted key remains the
production integration step.

The bundled footage is documented in [MEDIA_SOURCES.md](MEDIA_SOURCES.md).
