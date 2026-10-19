(function () {
  "use strict";

  const AUTH_TIMEOUT = 10000;
  const MAX_RETRIES = 3;
  const RETRY_DELAY = 700;

  function sleep(ms) {
    return new Promise(function (resolve) {
      setTimeout(resolve, ms);
    });
  }

  function withTimeout(promise, ms, message) {
    return Promise.race([
      promise,
      new Promise(function (_, reject) {
        setTimeout(function () {
          reject(new Error(message));
        }, ms);
      })
    ]);
  }

  async function getAdminSession(options = {}) {
    const redirect =
      options.redirect ||
      (
        window.location.pathname +
        window.location.search
      );

    if (!window.supabaseClient) {
      throw new Error(
        "Supabase authentication is not initialized"
      );
    }

    let session = null;

    try {
      if (
        typeof window.getStableSession ===
        "function"
      ) {
        session = await withTimeout(
          window.getStableSession({
            retries: 8,
            delay: 300,
            eventWait: 2500
          }),
          AUTH_TIMEOUT,
          "Authentication session check timed out"
        );
      } else {
        const result = await withTimeout(
          window.supabaseClient.auth.getSession(),
          AUTH_TIMEOUT,
          "Authentication session check timed out"
        );

        session =
          result?.data?.session || null;
      }
    } catch (error) {
      console.warn(
        "ADMIN AUTH: session check failed",
        error
      );
    }

    if (session?.access_token) {
      return session;
    }

    /*
     * A missing usable session can still be caused by
     * session restoration timing. Try refresh once.
     */
    try {
      const refreshed =
        await withTimeout(
          window.supabaseClient.auth.refreshSession(),
          AUTH_TIMEOUT,
          "Authentication refresh timed out"
        );

      const refreshedSession =
        refreshed?.data?.session || null;

      if (refreshedSession?.access_token) {
        return refreshedSession;
      }
    } catch (error) {
      console.warn(
        "ADMIN AUTH: refreshSession failed",
        error
      );
    }

    /*
     * At this point there really is no usable browser
     * session. This is the correct situation to redirect.
     */
    console.warn(
      "ADMIN AUTH: no usable session"
    );

    window.location.replace(
      "/login?redirect=" +
        encodeURIComponent(redirect)
    );

    throw new Error(
      "Authentication session unavailable"
    );
  }

  async function refreshSession() {
    try {
      if (
        typeof window.refreshStableSession ===
        "function"
      ) {
        const refreshed =
          await withTimeout(
            window.refreshStableSession(),
            AUTH_TIMEOUT,
            "Session refresh timed out"
          );

        if (refreshed?.access_token) {
          return refreshed;
        }
      }

      const result =
        await withTimeout(
          window.supabaseClient.auth.refreshSession(),
          AUTH_TIMEOUT,
          "Session refresh timed out"
        );

      return result?.data?.session || null;

    } catch (error) {
      console.warn(
        "ADMIN AUTH: session refresh failed",
        error
      );

      return null;
    }
  }

  async function performRequest(
    url,
    options,
    session
  ) {
    const headers = {
      "Content-Type": "application/json",
      ...(options.headers || {}),
      Authorization:
        "Bearer " + session.access_token
    };

    return withTimeout(
      fetch(
        url,
        {
          ...options,
          headers
        }
      ),
      AUTH_TIMEOUT,
      "Request timed out"
    );
  }

  async function adminFetch(
    url,
    options = {}
  ) {
    let session =
      await getAdminSession({
        redirect:
          window.location.pathname +
          window.location.search
      });

    /*
     * We make a small number of attempts because a
     * Supabase connection can occasionally terminate
     * while the browser session itself remains valid.
     */
    for (
      let attempt = 1;
      attempt <= MAX_RETRIES;
      attempt++
    ) {
      let response;

      try {
        response =
          await performRequest(
            url,
            options,
            session
          );
      } catch (error) {
        console.warn(
          "ADMIN AUTH: request failed, attempt " +
            attempt,
          error
        );

        if (attempt < MAX_RETRIES) {
          await sleep(RETRY_DELAY);
          continue;
        }

        throw error;
      }

      /*
       * Normal successful response.
       */
      if (response.ok) {
        return response;
      }

      /*
       * 401 is the only status that should trigger
       * an access-token refresh.
       */
      if (response.status === 401) {
        console.warn(
          "ADMIN AUTH: access token rejected, refreshing"
        );

        const refreshed =
          await refreshSession();

        if (refreshed?.access_token) {
          session = refreshed;
          continue;
        }

        /*
         * No refreshed session means the browser's
         * authentication session is genuinely unusable.
         */
        window.location.replace(
          "/login?redirect=" +
            encodeURIComponent(
              window.location.pathname +
                window.location.search
            )
        );

        throw new Error(
          "Admin authentication required"
        );
      }

      /*
       * 403 means the user is authenticated but does
       * not have permission for this resource.
       *
       * IMPORTANT:
       * Do not redirect to login.
       *
       * Return the response so the calling page can
       * display the actual authorization error.
       */
      if (response.status === 403) {
        console.warn(
          "ADMIN AUTH: authenticated but forbidden"
        );

        return response;
      }

      /*
       * 503 is a temporary backend/authentication
       * service problem. Retry without changing the
       * user's session.
       */
      if (response.status === 503) {
        console.warn(
          "ADMIN AUTH: temporary service failure, attempt " +
            attempt
        );

        if (attempt < MAX_RETRIES) {
          await sleep(RETRY_DELAY);
          continue;
        }

        return response;
      }

      /*
       * Other HTTP errors are returned to the caller.
       * They are not authentication failures.
       */
      return response;
    }

    throw new Error(
      "Unable to complete authenticated request"
    );
  }

  window.getAdminSession =
    getAdminSession;

  window.refreshAdminSession =
    refreshSession;

  window.adminFetch =
    adminFetch;

})();
