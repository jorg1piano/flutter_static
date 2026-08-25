// flutter_static multiview bootstrap
{{flutter_js}}
{{flutter_build_config}}
// Works from the catalog's /live/ and from a standalone page: resolve
// bases from this script's own URL.
const BASE = new URL('.', document.currentScript.src).href;
const onEntrypointLoaded = async (engineInitializer) => {
    // The engine resolves assets and CanvasKit against these, not the
    // loader config above, which only covers the entrypoint.
    const engine = await engineInitializer.initializeEngine({
      multiViewEnabled: true,
      assetBase: BASE,
      canvasKitBaseUrl: BASE + 'canvaskit/',
    });
    const app = await engine.runApp();
    window.flutterStaticApp = app;
    let host = document.getElementById('host');
    const storyId = window._flutterStaticStory ||
        new URLSearchParams(location.search).get('storyId');
    if (!host && storyId) {
      // Standalone (dev server) page: fill it with a single view.
      document.body.style.cssText = 'margin:0;height:100vh;background:#131518';
      host = document.createElement('div');
      host.id = 'host';
      host.style.cssText = 'position:absolute;inset:0';
      document.body.appendChild(host);
    }
    if (host && storyId) {
      app.addView({hostElement: host, initialData: {storyId: storyId}});
    }
    // Pages that mount their own views (the gallery) listen for this.
    document.dispatchEvent(new CustomEvent('flutter-static-ready', {detail: app}));
};
_flutter.loader.load({
  config: {
    entrypointBaseUrl: BASE,
    assetBase: BASE,
    canvasKitBaseUrl: BASE + 'canvaskit/',
  },
  onEntrypointLoaded: onEntrypointLoaded,
});
