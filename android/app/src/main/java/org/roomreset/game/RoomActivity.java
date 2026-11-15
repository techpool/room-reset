package org.roomreset.game;

import android.app.Activity;
import android.content.Intent;
import android.content.SharedPreferences;
import android.net.Uri;
import android.os.Bundle;
import android.webkit.JavascriptInterface;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.view.WindowInsets;
import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.util.Locale;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import org.json.JSONArray;
import org.json.JSONObject;

public final class RoomActivity extends Activity {
    private static final int PICK = 8;
    private static final String ORIGIN = "roomreset.invalid";
    private static final ExecutorService FILES = Executors.newSingleThreadExecutor();
    private WebView view;
    private Object pickerId;
    private SharedPreferences state;
    private volatile boolean picking;

    @Override public void onCreate(Bundle saved) {
        super.onCreate(saved);
        state = getSharedPreferences("room-state", MODE_PRIVATE);
        if (saved != null) picking = saved.getBoolean("picking");
        view = new WebView(this);
        view.setOnApplyWindowInsetsListener((v, insets) -> {
            if (android.os.Build.VERSION.SDK_INT >= 30) {
                android.graphics.Insets space = insets.getInsets(WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout());
                v.setPadding(space.left, space.top, space.right, space.bottom);
            }
            return insets;
        });
        view.setBackgroundColor(0xfffaf4e6);
        view.getSettings().setJavaScriptEnabled(true);
        view.getSettings().setDomStorageEnabled(true);
        view.getSettings().setAllowFileAccess(false);
        view.getSettings().setAllowContentAccess(false);
        view.getSettings().setBlockNetworkLoads(true);
        view.setWebViewClient(new WebViewClient() {
            @Override public boolean shouldOverrideUrlLoading(WebView v, WebResourceRequest request) {
                // All top-level content ships with this application.
                return true;
            }
            @Override public WebResourceResponse shouldInterceptRequest(WebView v, WebResourceRequest request) {
                Uri uri = request.getUrl();
                String path = uri.getPath();
                if ("https".equals(uri.getScheme()) && ORIGIN.equals(uri.getHost()) && path != null
                        && path.startsWith("/") && !path.contains("..") && !path.contains("\\")
                        && !path.contains("//") && !path.contains("\0")) {
                    try {
                        String type = mime(path);
                        return new WebResourceResponse(type, type.startsWith("text/") || type.contains("javascript") ? "UTF-8" : null,
                                getAssets().open(path.substring(1)));
                    } catch (IOException ignored) { }
                }
                return new WebResourceResponse("text/plain", "UTF-8", 404, "Missing", null,
                        new ByteArrayInputStream(new byte[0]));
            }
        });
        view.addJavascriptInterface(new Bridge(), "RoomNative");
        setContentView(view);
        view.loadUrl("https://" + ORIGIN + "/index.html");
    }

    private static String mime(String path) {
        String ext = path.substring(path.lastIndexOf('.') + 1).toLowerCase(Locale.ROOT);
        switch (ext) {
            case "js": case "mjs": return "application/javascript";
            case "css": return "text/css";
            case "html": return "text/html";
            case "json": return "application/json";
            case "woff2": return "font/woff2";
            default:
                String type = android.webkit.MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext);
                return type == null ? "application/octet-stream" : type;
        }
    }

    public final class Bridge {
        @JavascriptInterface public void postMessage(String input) {
            if (input == null || input.length() > 1000000) return;
            FILES.execute(() -> {
                Object id = null;
                try {
                    JSONObject call = new JSONObject(input);
                    id = call.get("id");
                    if (!(id instanceof String || id instanceof Number)) return;
                    String op = call.getString("op");
                    if (picking) throw new IOException("Finish choosing a folder first.");
                    if ("pick".equals(op)) {
                        Object requestId = id;
                        picking = true;
                        runOnUiThread(() -> choose(requestId));
                        return;
                    }
                    String selected = state.getString("tree", null);
                    if (selected == null && "scan".equals(op)) { reply(id, null, null); return; }
                    if (selected == null) throw new IOException("Choose a folder first.");
                    FolderRoom room;
                    if ("scan".equals(op)) {
                        // An expired grant, ejected drive or deleted folder must lead back to the picker.
                        try {
                            room = new FolderRoom(RoomActivity.this, Uri.parse(selected));
                            reply(id, room.scan(), null);
                        } catch (SecurityException | java.io.FileNotFoundException unavailable) {
                            reply(id, null, null);
                        }
                        return;
                    }
                    room = new FolderRoom(RoomActivity.this, Uri.parse(selected));
                    Object result;
                    switch (op) {
                        case "tidy": result = room.tidy(call.getJSONObject("args").getJSONArray("ids")); break;
                        case "undo": result = room.undo(); break;
                        case "purge": result = room.purge(); break;
                        default: throw new IOException("Unknown room action.");
                    }
                    reply(id, result, null);
                } catch (Exception error) { reply(id, null, friendly(error)); }
            });
        }
    }

    private static String friendly(Exception e) {
        if (e instanceof SecurityException) return "Folder access expired. Choose it again.";
        return e.getMessage() == null ? "The folder could not complete this action." : e.getMessage();
    }

    private void choose(Object id) {
        pickerId = id;
        try {
            Intent pick = new Intent(Intent.ACTION_OPEN_DOCUMENT_TREE);
            pick.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                    | Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION | Intent.FLAG_GRANT_PREFIX_URI_PERMISSION);
            startActivityForResult(pick, PICK);
        } catch (RuntimeException error) {
            picking = false;
            reply(id, null, "The folder picker could not open.");
        }
    }

    @Override protected void onSaveInstanceState(Bundle out) {
        super.onSaveInstanceState(out);
        out.putBoolean("picking", picking);
    }

    @Override protected void onActivityResult(int requestCode, int resultCode, Intent result) {
        super.onActivityResult(requestCode, resultCode, result);
        if (requestCode != PICK) return;
        Object id = pickerId;
        pickerId = null;
        FILES.execute(() -> {
            try {
                if (resultCode != RESULT_OK || result == null || result.getData() == null) {
                    reply(id, null, null);
                    return;
                }
                Uri tree = result.getData();
                int flags = Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION;
                getContentResolver().takePersistableUriPermission(tree, result.getFlags() & flags);
                JSONObject resultScan = new FolderRoom(this, tree).scan();
                String previous = state.getString("tree", null);
                if (!state.edit().putString("tree", tree.toString()).commit()) throw new IOException("Could not save the selected folder.");
                if (previous != null && !tree.toString().equals(previous)) {
                    try { getContentResolver().releasePersistableUriPermission(Uri.parse(previous), flags); }
                    catch (SecurityException ignored) { /* The provider may have revoked its grant already. */ }
                }
                reply(id, resultScan, null);
            } catch (Exception error) { reply(id, null, friendly(error)); }
            finally { picking = false; }
        });
    }

    private void reply(Object id, Object value, String error) {
        if (id == null) return;
        try {
            JSONObject result = new JSONObject().put("ok", error == null);
            if (error == null) result.put("value", value == null ? JSONObject.NULL : value);
            else result.put("error", error);
            String args = new JSONArray().put(id).put(result).toString()
                    .replace("\u2028", "\\u2028").replace("\u2029", "\\u2029");
            runOnUiThread(() -> {
                if (!isFinishing() && !isDestroyed()) view.evaluateJavascript(
                        "if(window.roomReply)window.roomReply.apply(null," + args + ")", null);
            });
        } catch (Exception ignored) { }
    }

    @Override public void onDestroy() {
        view.removeJavascriptInterface("RoomNative");
        view.destroy();
        super.onDestroy();
    }
}
