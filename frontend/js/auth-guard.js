(function () {
  "use strict";

  const currentPath =
    window.location.pathname + window.location.search;

  const loginUrl =
    "/login?redirect=" + encodeURIComponent(currentPath);

  const AUTH_RETRIES = 4;
  const RETRY_DELAY = 700;

  document.documentElement.classList.add("auth-checking");

  const style = document.createElement("style");
  style.id = "auth-guard-style";
  style.textContent = `
    html.auth-checking body {
      visibility: hidden !important;
    }

    html.auth-checking::before {
      content: "Checking authorization...";
      position: fixed;
      inset: 0;
      z-index: 2147483647;
      display: flex;
      align-items: center;
      justify-content: center;
      background: #f4efe5;
      color: #18242b;
      font-family: system-ui, sans-serif;
      font-size: 15px;
    }
  `;

  document.head.appendChild(style);

  function sleep(ms) {
    return new Promise(function (resolve) {
      setTimeout(resolve, ms);
    });
  }

  function allowPage() {
    document.documentElement.classList.remove(
      "auth-checking"
    );
  }

  function redirectToLogin() {
    window.location.replace(loginUrl);
  }

  async function getSession() {
    if (!window.supabaseClient) {
      throw new Error(
        "Supabase client is not initialized."
      );
    }

    if (
      typeof window.getStableSession === "function"
    ) {
      const result =
        await window.getStableSession({
          retries: 8,
          delay: 300
        });

      return result?.session || result || null;
    }

    for (let attempt = 1; attempt <= 8; attempt++) {
      try {
        const result =
          await window.supabaseClient.auth.getSession();

        if (
          !result.error &&
          result.data?.session
        ) {
          return result.data.session;
        }
      } catch (error) {
        console.warn(
          "AUTH GUARD: session attempt " +
            attempt +
            " failed",
          error
        );
      }

      if (attempt < 8) {
        await sleep(300);
      }
    }

    return null;
  }

  async function requestAdminRole(session) {
    return fetch("/api/auth/me", {
      method: "GET",
      headers: {
        Authorization:
          "Bearer " + session.access_token,
        Accept: "application/json"
      },
      credentials: "same-origin",
      cache: "no-store"
    });
  }

  async function checkAdmin(session) {
    let currentSession = session;

    for (
      let attempt = 1;
      attempt <= AUTH_RETRIES;
      attempt++
    ) {
      let response;

      try {
        response =
          await requestAdminRole(currentSession);
      } catch (error) {
        console.warn(
          "AUTH GUARD: role request failed, attempt " +
            attempt,
          error
        );

        if (attempt < AUTH_RETRIES) {
          await sleep(RETRY_DELAY);
          continue;
        }

        // Network failure after retries:
        // do NOT log the user out.
        throw new Error(
          "Authentication service is temporarily unavailable."
        );
      }

      /*
       * 200 = authenticated and profile loaded.
       */
      if (response.ok) {
        const data =
          await response.json().catch(
            function () {
              return {};
            }
          );

        return data?.role === "admin";
      }

      /*
       * 401 = token rejected.
       *
       * This is the only response here that should
       * trigger a session refresh.
       */
      if (response.status === 401) {
        console.warn(
          "AUTH GUARD: access token rejected"
        );

        try {
          if (
            typeof window.refreshStableSession ===
            "function"
          ) {
            const refreshed =
              await window.refreshStableSession();

            if (refreshed?.access_token) {
              currentSession = refreshed;
              continue;
            }
          } else {
            const refreshed =
              await window.supabaseClient.auth
                .refreshSession();

            const refreshedSession =
              refreshed?.data?.session || null;

            if (
              refreshedSession?.access_token
            ) {
              currentSession =
                refreshedSession;
              continue;
            }
          }
        } catch (error) {
          console.warn(
            "AUTH GUARD: session refresh failed",
            error
          );
        }

        // Genuine authentication failure.
        return false;
      }

      /*
       * 403 = authenticated but not authorized.
       * Never send the user to login for this.
       */
      if (response.status === 403) {
        console.warn(
          "AUTH GUARD: authenticated but not authorized"
        );

        return false;
      }

      /*
       * 503 = temporary authentication/backend
       * service problem. Retry instead of logging out.
       */
      if (response.status === 503) {
        console.warn(
          "AUTH GUARD: authentication service temporarily unavailable, attempt " +
            attempt
        );

        if (attempt < AUTH_RETRIES) {
          await sleep(RETRY_DELAY);
          continue;
        }

        throw new Error(
          "Authentication service is temporarily unavailable."
        );
      }

      /*
       * Other server errors are not proof that the
       * session is invalid.
       */
      console.warn(
        "AUTH GUARD: /api/auth/me returned",
        response.status
      );

      if (attempt < AUTH_RETRIES) {
        await sleep(RETRY_DELAY);
        continue;
      }

      throw new Error(
        "Unable to verify administrator access."
      );
    }

    throw new Error(
      "Unable to verify administrator access."
    );
  }

  async function guard() {
    try {
      const session = await getSession();

      if (
        !session ||
        !session.access_token
      ) {
        redirectToLogin();
        return;
      }

      const path =
        window.location.pathname;

      if (
        path === "/admin" ||
        path.startsWith("/admin/")
      ) {
        let isAdmin;

        try {
          isAdmin =
            await checkAdmin(session);
        } catch (error) {
          console.error(
            "AUTH GUARD: temporary verification failure",
            error
          );

          /*
           * Do NOT redirect to login.
           *
           * The browser still has a valid Supabase
           * session. The backend simply could not
           * verify it temporarily.
           */
          allowPage();

          const message =
            document.createElement("div");

          message.textContent =
            "Authentication service temporarily unavailable. Please refresh in a moment.";

          message.style.cssText = `
            position: fixed;
            top: 12px;
            left: 50%;
            transform: translateX(-50%);
            z-index: 2147483646;
            max-width: calc(100% - 24px);
            padding: 10px 16px;
            border-radius: 8px;
            background: #fff3cd;
            color: #664d03;
            border: 1px solid #ffecb5;
            font: 14px system-ui, sans-serif;
            text-align: center;
            box-shadow: 0 4px 16px rgba(0,0,0,.08);
          `;

          document.body.appendChild(message);

          setTimeout(function () {
            message.remove();
          }, 6000);

          return;
        }

        if (!isAdmin) {
          /*
           * Session exists but the account is not an
           * administrator. This is an authorization
           * failure, not a login failure.
           */
          window.location.replace("/");
          return;
        }
      }

      allowPage();

    } catch (error) {
      console.error(
        "AUTH GUARD ERROR:",
        error
      );

      /*
       * Only a genuinely missing session reaches
       * redirectToLogin().
       *
       * Other errors are kept on the current page.
       */
      if (
        error &&
        error.message ===
          "Supabase client is not initialized."
      ) {
        redirectToLogin();
        return;
      }

      allowPage();
    }
  }

  window.authGuard = {
    check: guard
  };

  if (
    document.readyState === "loading"
  ) {
    document.addEventListener(
      "DOMContentLoaded",
      guard,
      { once: true }
    );
  } else {
    guard();
  }
})();
