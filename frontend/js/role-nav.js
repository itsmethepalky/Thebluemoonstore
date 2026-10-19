(function () {
  "use strict";

  /*
   * =========================================================================
   * THE BLUE MOON — ROLE NAVIGATION
   * =========================================================================
   *
   * This script handles UI/navigation differences between customers
   * and administrators.
   *
   * IMPORTANT:
   * - It never signs users out.
   * - It never treats a temporary session restoration failure as logout.
   * - Authentication/authorization remains server-side.
   */

  function sleep(ms) {
    return new Promise(function (resolve) {
      setTimeout(resolve, ms);
    });
  }

  async function getStableSession() {
    if (
      typeof window.getStableSession === "function"
    ) {
      return window.getStableSession({
        retries: 8,
        delay: 300
      });
    }

    /*
     * Fallback for pages that may have an older script-loading order.
     */
    if (!window.supabaseClient) {
      console.error(
        "ROLE NAV: Supabase client is unavailable"
      );
      return null;
    }

    for (let attempt = 1; attempt <= 8; attempt++) {
      try {
        const result =
          await window.supabaseClient.auth.getSession();

        if (
          !result.error &&
          result.data &&
          result.data.session
        ) {
          return result.data.session;
        }
      } catch (error) {
        console.warn(
          "ROLE NAV: session attempt " + attempt + " failed",
          error
        );
      }

      if (attempt < 8) {
        await sleep(300);
      }
    }

    return null;
  }

  async function getRole(session) {
    if (!session || !session.access_token) {
      return null;
    }

    const MAX_ATTEMPTS = 4;
    const RETRY_DELAY = 700;

    async function requestRole(currentSession) {
      return fetch(
        "/api/auth/me",
        {
          method: "GET",
          headers: {
            Authorization:
              "Bearer " + currentSession.access_token,
            Accept: "application/json"
          },
          cache: "no-store"
        }
      );
    }

    let currentSession = session;

    for (
      let attempt = 1;
      attempt <= MAX_ATTEMPTS;
      attempt++
    ) {
      let response;

      try {
        response =
          await requestRole(currentSession);
      } catch (error) {
        console.warn(
          "ROLE NAV: role request failed, attempt " +
            attempt,
          error
        );

        if (attempt < MAX_ATTEMPTS) {
          await sleep(RETRY_DELAY);
          continue;
        }

        return null;
      }

      /*
       * Successful authentication.
       */
      if (response.ok) {
        const data =
          await response.json().catch(
            function () {
              return {};
            }
          );

        return data.role || null;
      }

      /*
       * 401 means the access token may have expired.
       * Refresh once and retry.
       */
      if (response.status === 401) {
        console.warn(
          "ROLE NAV: access token rejected, attempting refresh"
        );

        try {
          let refreshedSession = null;

          if (
            typeof window.refreshStableSession ===
            "function"
          ) {
            refreshedSession =
              await window.refreshStableSession();
          } else if (
            window.supabaseClient
          ) {
            const refreshed =
              await window.supabaseClient.auth
                .refreshSession();

            refreshedSession =
              refreshed?.data?.session || null;
          }

          if (
            refreshedSession?.access_token
          ) {
            currentSession =
              refreshedSession;

            continue;
          }
        } catch (error) {
          console.warn(
            "ROLE NAV: session refresh failed",
            error
          );
        }

        /*
         * Actual authentication failure.
         */
        return null;
      }

      /*
       * 403 means authenticated but not authorized.
       * It is not a reason to sign out.
       */
      if (response.status === 403) {
        console.warn(
          "ROLE NAV: authenticated but not authorized"
        );
        return null;
      }

      /*
       * 503 means the backend/authentication service
       * is temporarily unavailable.
       */
      if (response.status === 503) {
        console.warn(
          "ROLE NAV: authentication service temporarily unavailable, attempt " +
            attempt
        );

        if (attempt < MAX_ATTEMPTS) {
          await sleep(RETRY_DELAY);
          continue;
        }

        return null;
      }

      /*
       * Other errors should not be interpreted as
       * an expired session.
       */
      console.warn(
        "ROLE NAV: /api/auth/me returned",
        response.status
      );

      if (attempt < MAX_ATTEMPTS) {
        await sleep(RETRY_DELAY);
        continue;
      }

      return null;
    }

    return null;
  }

  function setAdminNavigation() {
    document.documentElement.classList.add(
      "is-admin-user"
    );

    document.querySelectorAll(
      'a[href="/account"], a[href="/orders"]'
    ).forEach(function (link) {
      const href =
        link.getAttribute("href");

      if (href === "/account") {
        link.setAttribute(
          "href",
          "/admin/account"
        );

        link.dataset.originalHref =
          "/account";

        const icon =
          link.querySelector("i");

        if (icon) {
          icon.className =
            "bi bi-person-gear";
        }

        const textNode =
          Array.from(link.childNodes).find(
            function (node) {
              return (
                node.nodeType === Node.TEXT_NODE &&
                node.textContent.trim()
              );
            }
          );

        if (textNode) {
          textNode.textContent =
            " Admin Account";
        }
      }

      if (href === "/orders") {
        link.setAttribute(
          "href",
          "/admin/orders"
        );

        link.dataset.originalHref =
          "/orders";

        const icon =
          link.querySelector("i");

        if (icon) {
          icon.className =
            "bi bi-receipt";
        }

        const textNode =
          Array.from(link.childNodes).find(
            function (node) {
              return (
                node.nodeType === Node.TEXT_NODE &&
                node.textContent.trim()
              );
            }
          );

        if (textNode) {
          textNode.textContent =
            " Admin Orders";
        }
      }
    });

    document.querySelectorAll("a")
      .forEach(function (link) {
        const href =
          link.getAttribute("href");

        const text =
          link.textContent
            .trim()
            .toLowerCase();

        if (
          text === "dashboard" ||
          text === "my dashboard" ||
          text === "home"
        ) {
          if (
            href === "/" ||
            href === "/dashboard"
          ) {
            link.setAttribute(
              "href",
              "/admin"
            );
          }
        }
      });

    document.querySelectorAll(
      'a[href="/login"], a[href="/register"]'
    ).forEach(function (link) {
      link.classList.add(
        "admin-hide-for-admin"
      );
    });

    document.querySelectorAll(
      'a[href="/cart"], a[href="/checkout"]'
    ).forEach(function (link) {
      link.classList.add(
        "admin-customer-control"
      );
    });

    const navs =
      document.querySelectorAll(
        "nav, .site-nav, .main-nav, .navbar, .header-nav"
      );

    navs.forEach(function (nav) {
      if (
        nav.querySelector(
          'a[href="/admin"]'
        )
      ) {
        return;
      }

      const link =
        document.createElement("a");

      link.href = "/admin";
      link.className =
        "admin-global-link";

      link.setAttribute(
        "aria-label",
        "Admin Dashboard"
      );

      link.innerHTML =
        '<i class="bi bi-speedometer2"></i>' +
        '<span>Admin Dashboard</span>';

      nav.appendChild(link);
    });

    document.body.classList.add(
      "admin-session-active"
    );
  }

  function hideCustomerControlsForAdmin() {
    document.querySelectorAll(
      'a[href="/account"], a[href="/orders"]'
    ).forEach(function (link) {
      link.classList.add(
        "admin-customer-control"
      );
    });
  }

  function protectCustomerRoute(role) {
    const path =
      window.location.pathname
        .replace(/\/+$/, "") || "/";

    if (
      role === "admin" &&
      (
        path === "/account" ||
        path === "/orders"
      )
    ) {
      window.location.replace("/admin");
      return true;
    }

    return false;
  }

  async function init() {
    const session =
      await getStableSession();

    /*
     * No session is not an error here.
     *
     * Public pages use this script too, so we simply leave the page
     * alone instead of redirecting or signing anyone out.
     */
    if (!session) {
      return;
    }

    const role =
      await getRole(session);

    /*
     * If role lookup temporarily fails, do nothing.
     * Never interpret that as logout.
     */
    if (!role) {
      return;
    }

    if (protectCustomerRoute(role)) {
      return;
    }

    if (role === "admin") {
      setAdminNavigation();
      hideCustomerControlsForAdmin();
    }
  }

  /*
   * Keep browser UI synchronized with Supabase auth state.
   *
   * We intentionally do not redirect or sign out from this callback.
   * Supabase itself remains the source of truth for authentication.
   */
  function watchAuthState() {
    if (!window.supabaseClient) {
      return;
    }

    window.supabaseClient.auth.onAuthStateChange(
      function (event, session) {
        console.log(
          "ROLE NAV AUTH EVENT:",
          event,
          session
            ? "session-present"
            : "no-session"
        );
      }
    );
  }

  function start() {
    watchAuthState();
    init();
  }

  if (
    document.readyState === "loading"
  ) {
    document.addEventListener(
      "DOMContentLoaded",
      start,
      { once: true }
    );
  } else {
    start();
  }

  

})();
