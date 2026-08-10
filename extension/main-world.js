// main-world.js — runs in the page's JS context (MAIN world)
// Registers a React DevTools hook and provides fiber tree access.

(function () {
  "use strict";

  if (window.__remarcMainWorldLoaded) return;
  window.__remarcMainWorldLoaded = true;

  // Register DevTools hook BEFORE React loads (document_start ensures this)
  if (!window.__REACT_DEVTOOLS_GLOBAL_HOOK__) {
    window.__REACT_DEVTOOLS_GLOBAL_HOOK__ = {
      renderers: new Map(),
      supportsFiber: true,
      inject(renderer) {
        const id = this.renderers.size + 1;
        this.renderers.set(id, renderer);
        return id;
      },
      onCommitFiberRoot() {},
      onCommitFiberUnmount() {},
    };
  }

  // Fiber access utilities
  function getFiberFromElement(element) {
    const keys = Object.keys(element);
    const fiberKey = keys.find(
      (k) => k.startsWith("__reactFiber$") || k.startsWith("__reactInternalInstance$")
    );
    return fiberKey ? element[fiberKey] : null;
  }

  function getComponentName(fiber) {
    if (!fiber || !fiber.type) return null;
    if (typeof fiber.type === "string") return null; // HTML element
    return fiber.type.displayName || fiber.type.name || null;
  }

  function getSourceLocation(fiber) {
    if (!fiber || !fiber._debugSource) return null;
    const src = fiber._debugSource;
    const file = src.fileName || "";
    const line = src.lineNumber || "";
    const col = src.columnNumber || "";
    return line ? `${file}:${line}${col ? ":" + col : ""}` : file;
  }

  function getParentElement(element) {
    if (element.parentElement) return element.parentElement;
    const root = element.getRootNode();
    return root instanceof ShadowRoot ? root.host : null;
  }

  function deepElementFromPoint(x, y) {
    let element = document.elementFromPoint(x, y);
    while (element?.shadowRoot) {
      const deeper = element.shadowRoot.elementFromPoint(x, y);
      if (!deeper || deeper === element) break;
      element = deeper;
    }
    return element;
  }

  function meaningfulClasses(element, limit = 2) {
    if (!element.className || typeof element.className !== "string") return [];
    return element.className
      .trim()
      .split(/\s+/)
      .map((className) => className.replace(/[_-][a-zA-Z0-9]{5,}$/, ""))
      .filter((className, index, all) =>
        className.length > 2 &&
        !/^[a-z]{1,2}$/.test(className) &&
        all.indexOf(className) === index
      )
      .slice(0, limit);
  }

  function getCSSSelector(element) {
    if (element.id) return `#${CSS.escape(element.id)}`;

    const dataSelector = ["data-testid", "data-test", "data-cy", "aria-label"]
      .map((attr) => {
        const value = element.getAttribute(attr);
        return value ? `[${attr}="${CSS.escape(value)}"]` : null;
      })
      .find(Boolean);
    if (dataSelector) return `${element.tagName.toLowerCase()}${dataSelector}`;

    const parts = [];
    let el = element;
    while (el && el !== document.body && el !== document.documentElement) {
      let selector = el.tagName.toLowerCase();
      if (el.id) {
        parts.unshift(`#${CSS.escape(el.id)}`);
        break;
      }

      const classes = meaningfulClasses(el);
      if (classes.length) selector += "." + classes.map(CSS.escape).join(".");

      const parent = getParentElement(el);
      if (parent) {
        const siblings = Array.from(parent.children).filter((child) => child.tagName === el.tagName);
        if (siblings.length > 1) {
          selector += `:nth-child(${Array.from(parent.children).indexOf(el) + 1})`;
        }
      }

      parts.unshift(selector);
      el = parent;
    }

    return parts.join(" > ");
  }

  function getElementName(element) {
    const tag = element.tagName.toLowerCase();
    const ariaLabel = element.getAttribute("aria-label");
    const text = element.textContent?.trim().replace(/\s+/g, " ") || "";

    if (ariaLabel) return `${tag} [${ariaLabel.slice(0, 40)}]`;
    if (tag === "button") return text ? `button "${text.slice(0, 40)}"` : "button";
    if (tag === "a") return text ? `link "${text.slice(0, 40)}"` : "link";
    if (tag === "input" || tag === "textarea" || tag === "select") {
      return element.getAttribute("placeholder") || element.getAttribute("name") || tag;
    }
    if (/^h[1-6]$/.test(tag)) return text ? `${tag} "${text.slice(0, 60)}"` : tag;
    if (["p", "span", "label", "li", "strong", "em", "code"].includes(tag) && text.length <= 80) {
      return text ? `${tag} "${text}"` : tag;
    }

    const classes = meaningfulClasses(element, 2);
    if (classes.length) return classes.join(" ");
    return tag === "div" ? "container" : tag;
  }

  function getElementPath(element, maxDepth = 4) {
    const parts = [];
    let current = element;
    let depth = 0;

    while (current && depth < maxDepth) {
      const tag = current.tagName.toLowerCase();
      if (tag === "html" || tag === "body") break;

      let identifier = tag;
      if (current.id) {
        identifier = `#${current.id}`;
      } else {
        const classes = meaningfulClasses(current, 1);
        if (classes.length) identifier = `.${classes[0]}`;
      }

      parts.unshift(identifier);
      current = getParentElement(current);
      depth += 1;
    }

    return parts.join(" > ");
  }

  function getElementClasses(element) {
    return meaningfulClasses(element, 8).join(", ");
  }

  function nodeToElement(node) {
    if (!node) return null;
    return node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement;
  }

  function chooseSelectionElement(range, selectedText) {
    const candidates = [];
    const startElement = nodeToElement(range.startContainer);
    const commonElement = nodeToElement(range.commonAncestorContainer);

    if (startElement) candidates.push(startElement);
    for (const rect of Array.from(range.getClientRects())) {
      if (rect.width <= 0 || rect.height <= 0) continue;
      const pointElement = deepElementFromPoint(rect.left + rect.width / 2, rect.top + rect.height / 2);
      if (pointElement) candidates.push(pointElement);
      break;
    }
    if (commonElement) candidates.push(commonElement);

    const unique = candidates.filter((candidate, index, all) =>
      candidate &&
      candidate !== document.body &&
      candidate !== document.documentElement &&
      all.indexOf(candidate) === index
    );

    if (unique.length === 0) return null;

    const selectedNeedle = selectedText.slice(0, 80);
    const textTags = new Set(["P", "SPAN", "LABEL", "LI", "STRONG", "EM", "CODE", "A", "BUTTON", "H1", "H2", "H3", "H4", "H5", "H6"]);

    return unique
      .map((element, index) => {
        const rect = element.getBoundingClientRect();
        const text = element.textContent?.trim().replace(/\s+/g, " ") || "";
        const textMatch = selectedNeedle.length > 0 && text.includes(selectedNeedle) ? 1 : 0;
        const tagScore = textTags.has(element.tagName) ? 1 : 0;
        const area = Math.max(1, rect.width * rect.height);
        return { element, score: textMatch * 100 + tagScore * 10 - Math.log(area) - index * 0.01 };
      })
      .sort((a, b) => b.score - a.score)[0].element;
  }

  function buildIdentityContext(element, selectedText) {
    return {
      elementName: getElementName(element),
      elementPath: getElementPath(element),
      selectedText: selectedText || null,
      cssClasses: getElementClasses(element),
      selector: getCSSSelector(element),
    };
  }

  function walkFiberTree(element, selectedText) {
    let fiber = getFiberFromElement(element);
    const identity = buildIdentityContext(element, selectedText);
    if (!fiber) return identity;

    let componentName = null;
    let filePath = null;
    const chain = [];
    let current = fiber;
    let depth = 0;

    // Walk up the fiber tree collecting meaningful components. Mirrors
    // Agentation's "filtered" mode: skip framework wrappers (Provider,
    // ErrorBoundary, HOCs, Next.js internals); minified prod names (xC, _4)
    // fail the PascalCase + length check.
    while (current && depth < MAX_FIBER_DEPTH && chain.length < MAX_COMPONENT_CHAIN) {
      const name = getComponentName(current);
      if (isMeaningfulComponentName(name)) {
        if (!componentName) {
          componentName = name;
          filePath = getSourceLocation(current);
        }
        chain.push(name);
      }
      current = current.return;
      depth++;
    }

    const reactComponents = formatComponentChain(chain);

    return {
      componentName,
      filePath,
      reactComponents,
      ...identity,
    };
  }

  // Format the component chain with run-length encoding so repeated wrappers
  // like 6 nested <View>s collapse to "<View> x6" instead of dominating the
  // output. React Native and some design systems wrap everything in <View>.
  function formatComponentChain(chain) {
    if (chain.length === 0) return null;
    const parts = [];
    let i = 0;
    while (i < chain.length) {
      let j = i + 1;
      while (j < chain.length && chain[j] === chain[i]) j++;
      const count = j - i;
      parts.push(count > 1 ? `<${chain[i]}> x${count}` : `<${chain[i]}>`);
      i = j;
    }
    return parts.join(" ");
  }

  // --- React component name filtering (ported from Agentation) ---

  const MAX_FIBER_DEPTH = 30;
  const MAX_COMPONENT_CHAIN = 6;

  // Exact names that are always framework wrappers, never useful as labels.
  const FRAMEWORK_EXACT = new Set([
    "Component", "PureComponent", "Fragment", "Suspense", "Profiler",
    "StrictMode", "Routes", "Route", "Outlet",
    "Root", "ErrorBoundaryHandler", "HotReload", "Hot",
  ]);

  // Pattern-based framework filters: HOCs, providers, routers, Next.js internals.
  const FRAMEWORK_PATTERNS = [
    /Boundary$/,
    /BoundaryHandler$/,
    /Provider$/,
    /Consumer$/,
    /^(Inner|Outer)/,
    /Router$/,
    /^Client(Page|Segment|Root)/,
    /^Segment(ViewNode|Node)$/,
    /^LayoutSegment/,
    /^Server(Root|Component|Render)/,
    /^RSC/,
    /Context$/,
    /^Hot(Reload)?$/,
    /^(Dev|React)(Overlay|Tools|Root)/,
    /Overlay$/,
    /Handler$/,
    /^With[A-Z]/,
    /Wrapper$/,
    /^Root$/,
  ];

  function isMeaningfulComponentName(name) {
    if (!name || typeof name !== "string") return false;
    if (name.length < 3) return false;
    const first = name[0];
    if (first < "A" || first > "Z") return false; // PascalCase only
    if (FRAMEWORK_EXACT.has(name)) return false;
    return !FRAMEWORK_PATTERNS.some((p) => p.test(name));
  }

  // Enriched context — flat strings to match Agentation's wire format.
  function getEnrichedContext(element) {
    const cs = window.getComputedStyle(element);

    const styleEntries = [
      ["color", cs.color],
      ["backgroundColor", cs.backgroundColor],
      ["fontSize", cs.fontSize],
      ["fontWeight", cs.fontWeight],
      ["padding", cs.padding],
      ["margin", cs.margin],
      ["display", cs.display],
      ["position", cs.position],
      ["borderRadius", cs.borderRadius],
    ].filter(([, v]) => v != null && v !== "");
    const computedStyles = styleEntries.length > 0
      ? styleEntries.map(([k, v]) => `${k}: ${v}`).join("; ")
      : null;

    const a11yParts = [];
    const role = element.getAttribute("role");
    const ariaLabel = element.getAttribute("aria-label");
    const ariaDescribedby = element.getAttribute("aria-describedby");
    const ariaHidden = element.getAttribute("aria-hidden");
    const tabIndex = element.tabIndex !== -1 ? element.tabIndex : null;
    const focusable = element.tabIndex >= 0 || ["A","BUTTON","INPUT","SELECT","TEXTAREA"].includes(element.tagName);
    if (role) a11yParts.push(`role=${role}`);
    if (ariaLabel) a11yParts.push(`aria-label="${ariaLabel}"`);
    if (ariaDescribedby) a11yParts.push(`aria-describedby="${ariaDescribedby}"`);
    if (ariaHidden) a11yParts.push(`aria-hidden=${ariaHidden}`);
    if (tabIndex != null) a11yParts.push(`tabIndex=${tabIndex}`);
    a11yParts.push(`focusable=${focusable}`);
    const accessibility = a11yParts.join(", ") || null;

    const nearbyParts = [];
    const before = element.previousElementSibling?.textContent?.trim()?.substring(0, 100);
    const after = element.nextElementSibling?.textContent?.trim()?.substring(0, 100);
    if (before) nearbyParts.push(`before: "${before}"`);
    if (after) nearbyParts.push(`after: "${after}"`);
    const nearbyText = nearbyParts.join("; ") || null;

    const nearbyElements = getSiblingIdentifiers(element);

    const r = element.getBoundingClientRect();

    return {
      computedStyles,
      accessibility,
      nearbyText,
      nearbyElements,
      boundingBox: {
        x: Math.round(r.x),
        y: Math.round(r.y),
        width: Math.round(r.width),
        height: Math.round(r.height),
      },
      pageUrl: window.location.href,
    };
  }

  function getSiblingIdentifiers(element) {
    const parts = [];
    const parent = element.parentElement;
    if (!parent) return null;

    for (const child of parent.children) {
      if (child === element) continue;
      if (parts.length >= 4) break;
      const tag = child.tagName.toLowerCase();
      const id = child.id ? `#${child.id}` : "";
      const cls = child.className && typeof child.className === "string"
        ? "." + child.className.trim().split(/\s+/).slice(0, 3).join(".")
        : "";
      const snippet = child.textContent?.trim()?.substring(0, 60);
      const snippetPart = snippet ? ` "${snippet}"` : "";
      parts.push(`<${tag}${id}${cls}>${snippetPart}`);
    }
    return parts.length > 0 ? parts.join(" | ") : null;
  }

  // Expose to content script via postMessage
  window.addEventListener("message", (event) => {
    if (event.source !== window) return;

    if (event.data?.type === "__REMARC_GET_CONTEXT__") {
      const { selector, x, y, requestId, selection } = event.data;
      let element;
      let selectedText = null;

      if (selection) {
        const currentSelection = window.getSelection();
        if (currentSelection && !currentSelection.isCollapsed && currentSelection.rangeCount) {
          const range = currentSelection.getRangeAt(0);
          selectedText = currentSelection.toString().trim().substring(0, 500) || null;
          element = chooseSelectionElement(range, selectedText || "");
        }
      }

      if (!element && selector) {
        element = document.querySelector(selector);
      }
      if (!element && x !== undefined && y !== undefined) {
        element = deepElementFromPoint(x, y);
      }

      if (!element) {
        window.postMessage({ type: "__REMARC_CONTEXT_RESULT__", requestId, data: null }, "*");
        return;
      }

      const enriched = getEnrichedContext(element);
      const result = walkFiberTree(element, selectedText);

      // HyperFrames bridge — opt-in. If the page exposes
      // window.__remarcHFContext(element), append the structured HF context
      // string. Page-side bridge decides whether to filter by element
      // overlap or by time-window proximity.
      let hyperframesContext = null;
      try {
        if (typeof window.__remarcHFContext === "function") {
          const hf = window.__remarcHFContext(element);
          if (typeof hf === "string" && hf.trim().length > 0) {
            hyperframesContext = hf;
          }
        }
      } catch (e) {
        // Bridge errors must never break the existing capture path.
        // eslint-disable-next-line no-console
        console.warn("[Remarc] __remarcHFContext threw:", e);
      }

      window.postMessage({
        type: "__REMARC_CONTEXT_RESULT__",
        requestId,
        data: { ...result, ...enriched, hyperframesContext },
      }, "*");
    }
  });

  // HyperFrames quick-note bridge access. Content.js (ISOLATED world) cannot
  // read window.__remarcHFContext directly because globals don't cross worlds.
  // It postMessages this MAIN-world helper to get the current HF context with
  // no element target (used by the Alt+Shift+N quick-note hotkey).
  window.addEventListener("message", (event) => {
    if (event.source !== window) return;
    if (event.data?.type !== "__REMARC_GET_HF_CONTEXT__") return;
    const { requestId } = event.data;
    let hyperframesContext = null;
    try {
      if (typeof window.__remarcHFContext === "function") {
        const hf = window.__remarcHFContext(null);
        if (typeof hf === "string" && hf.trim().length > 0) {
          hyperframesContext = hf;
        }
      }
    } catch (e) {
      // eslint-disable-next-line no-console
      console.warn("[Remarc] __remarcHFContext threw:", e);
    }
    window.postMessage({
      type: "__REMARC_HF_CONTEXT_RESULT__",
      requestId,
      data: { hyperframesContext, pageUrl: window.location.href },
    }, "*");
  });
})();
