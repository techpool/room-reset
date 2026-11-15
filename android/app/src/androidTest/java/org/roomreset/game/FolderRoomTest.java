package org.roomreset.game;

import android.app.Instrumentation;
import android.app.UiAutomation;
import android.os.ParcelFileDescriptor;
import android.view.accessibility.AccessibilityNodeInfo;
import java.util.List;
import java.io.InputStream;
import android.content.Intent;
import android.content.SharedPreferences;
import android.webkit.WebView;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.TimeUnit;
import android.content.Context;
import android.net.Uri;
import android.os.Build;
import android.provider.DocumentsContract;
import android.provider.DocumentsContract.Document;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;
import org.json.JSONArray;
import org.json.JSONObject;
import org.junit.*;
import org.junit.runner.RunWith;
import java.io.IOException;
import java.io.OutputStream;
import java.util.UUID;
import static org.junit.Assert.*;

@RunWith(AndroidJUnit4.class)
public class FolderRoomTest {
    private Context context;
    private Uri fixture, tree;
    private String fixtureId;
    private TreeStore store;

    @Before public void setup() throws Exception {
        Assume.assumeTrue(Build.VERSION.SDK_INT >= 29);
        Instrumentation test = InstrumentationRegistry.getInstrumentation();
        context = test.getTargetContext();
        // Use a disposable emulator. Never displace an existing folder selection.
        Assume.assumeTrue(context.getSharedPreferences("room-state", Context.MODE_PRIVATE).getString("tree", null) == null);
        String name = "RoomResetTest-" + UUID.randomUUID();
        UiAutomation automation = test.getUiAutomation();
        try (ParcelFileDescriptor cmd = automation.executeShellCommand("mkdir -p /sdcard/Documents/" + name);
             InputStream answer = new ParcelFileDescriptor.AutoCloseInputStream(cmd)) {
            while (answer.read() != -1) { }
        }
        String authority = "com.android.externalstorage.documents";
        fixtureId = "primary:Documents/" + name;
        tree = DocumentsContract.buildTreeDocumentUri(authority, fixtureId);
        Uri initial = DocumentsContract.buildDocumentUri(authority, fixtureId);
        RoomActivity host = launchRoom(test);
        try {
            Intent chooser = new Intent(Intent.ACTION_OPEN_DOCUMENT_TREE);
            chooser.putExtra(DocumentsContract.EXTRA_INITIAL_URI, initial);
            chooser.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                    | Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION | Intent.FLAG_GRANT_PREFIX_URI_PERMISSION);
            test.runOnMainSync(() -> host.startActivityForResult(chooser, 8));
            clickSystemButton(automation, "Use this folder");
            clickSystemButton(automation, "Allow");
            long deadline = android.os.SystemClock.elapsedRealtime() + 120000;
            while (android.os.SystemClock.elapsedRealtime() < deadline
                    && context.getSharedPreferences("room-state", Context.MODE_PRIVATE).getString("tree", null) == null) {
                Thread.sleep(150);
            }
            assertEquals("The system picker must grant precisely the test directory", tree.toString(),
                    context.getSharedPreferences("room-state", Context.MODE_PRIVATE).getString("tree", null));
            fixture = DocumentsContract.buildDocumentUriUsingTree(tree, fixtureId);
            store = new TreeStore(context.getContentResolver(), tree);
        } finally {
            test.runOnMainSync(host::finish);
        }
    }

    private RoomActivity launchRoom(Instrumentation test) {
        Instrumentation.ActivityMonitor monitor = test.addMonitor(RoomActivity.class.getName(), null, false);
        try {
            context.startActivity(new Intent(context, RoomActivity.class)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TASK));
            RoomActivity activity = (RoomActivity) test.waitForMonitorWithTimeout(monitor, 180000);
            assertNotNull("The local game activity must open", activity);
            return activity;
        } finally {
            test.removeMonitor(monitor);
        }
    }

    private static void clickSystemButton(UiAutomation ui, String text) throws Exception {
        long deadline = android.os.SystemClock.elapsedRealtime() + 120000;
        while (android.os.SystemClock.elapsedRealtime() < deadline) {
            AccessibilityNodeInfo root = ui.getRootInActiveWindow();
            if (root != null) {
                List<AccessibilityNodeInfo> nodes = root.findAccessibilityNodeInfosByText(text);
                for (AccessibilityNodeInfo node : nodes) {
                    if (node.getText() == null || !text.equalsIgnoreCase(node.getText().toString())) continue;
                    while (node != null && !node.isClickable()) node = node.getParent();
                    if (node != null && node.isEnabled() && node.performAction(AccessibilityNodeInfo.ACTION_CLICK)) return;
                }
            }
            Thread.sleep(200);
        }
        fail("The system picker did not show " + text);
    }

    @After public void tearDown() throws Exception {
        if (fixture != null) {
            DocumentsContract.deleteDocument(context.getContentResolver(), fixture);
            context.getSharedPreferences("room-journal", Context.MODE_PRIVATE).edit().remove(tree.toString()).commit();
            try {
                context.getContentResolver().releasePersistableUriPermission(tree,
                        Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION);
            } catch (SecurityException ignored) { /* Deleting a root may already revoke the grant. */ }
        }
        if (tree != null && context != null) {
            context.getSharedPreferences("room-state", Context.MODE_PRIVATE).edit().remove("tree").commit();
        }
    }

    private Uri put(String name, String content) throws Exception {
        Uri uri = DocumentsContract.createDocument(context.getContentResolver(), fixture, "application/octet-stream", name);
        assertNotNull(uri);
        write(uri, content);
        return uri;
    }

    private void write(Uri uri, String content) throws Exception {
        try (OutputStream stream = context.getContentResolver().openOutputStream(uri, "wt")) {
            assertNotNull(stream);
            stream.write(content.getBytes("UTF-8"));
        }
    }

    private FolderRoom room() throws Exception { return new FolderRoom(context, tree); }
    private JSONArray ids(JSONObject snapshot) throws Exception {
        JSONArray items = snapshot.getJSONArray("items"), ids = new JSONArray();
        for (int i = 0; i < items.length(); i++) ids.put(items.getJSONObject(i).getString("id"));
        return ids;
    }
    private boolean atRoot(String name) throws IOException { return store.named(fixtureId, name) != null; }

    @Test public void organizedAndStagedFilesSurviveRestartAndUndoAsOneBatch() throws Exception {
        put("notes.txt", "paper");
        put("photo.jpg", "image");
        put("solo.zip", "archive");
        put("backup.archive.gz", "same-dump");
        put("backup copy.archive.gz", "same-dump");
        put("other.archive.gz", "unequal!!");
        put("receipt.pdf", "original");
        put("receipt (1).pdf", "original");
        put("secret.sqlite", "private");
        JSONObject before = room().scan();
        assertEquals(5, ids(before).length());
        JSONObject after = room().tidy(ids(before));
        assertEquals(0, ids(after).length());
        assertTrue(after.getBoolean("canUndo"));
        assertEquals(2, after.getInt("stagedCount"));
        assertTrue(atRoot("backup.archive.gz"));
        assertTrue(atRoot("receipt.pdf"));
        assertTrue(atRoot("secret.sqlite"));
        assertTrue(atRoot("other.archive.gz"));
        assertFalse(atRoot("notes.txt"));
        assertEquals(2, room().scan().getInt("stagedCount"));
        assertEquals(5, ids(room().undo()).length());
        assertTrue(atRoot("backup copy.archive.gz"));
        assertTrue(atRoot("receipt (1).pdf"));
        assertTrue(atRoot("notes.txt"));
        assertFalse(room().scan().getBoolean("canUndo"));
    }

    @Test public void purgeRechecksBothCopiesAndOnlyTouchesJournaledFiles() throws Exception {
        Uri original = put("drawing.png", "abcdef");
        put("drawing copy.png", "abcdef");
        put("manual.pdf", "paper");
        JSONObject staged = room().tidy(ids(room().scan()));
        assertEquals(1, staged.getInt("stagedCount"));
        write(original, "xxxxxx");
        try { room().purge(); fail("Changed keeper must block purge"); }
        catch (IOException expected) { assertTrue(expected.getMessage().contains("kept")); }
        TreeStore.Entry shelf = store.directory("Room Reset - Staged", false);
        Uri unrelated = DocumentsContract.createDocument(context.getContentResolver(),store.uri(shelf.id),"application/octet-stream","unrelated.bin");
        assertNotNull(unrelated);
        write(unrelated, "keep");
        write(original, "abcdef");
        Uri stagedUri = store.uri(store.named(shelf.id, "drawing copy.png").id);
        write(stagedUri, "fedcba");
        try { room().purge(); fail("Same-size edited staged file must survive"); }
        catch (IOException expected) { assertNotNull(store.named(shelf.id, "drawing copy.png")); }
        write(stagedUri, "abcdef");
        JSONObject done = room().purge();
        assertEquals(0, done.getInt("stagedCount"));
        assertTrue(atRoot("drawing.png"));
        assertNotNull(store.named(shelf.id, "unrelated.bin"));
        assertNull(store.named(shelf.id, "drawing copy.png"));
        assertTrue(room().undo().getJSONArray("items").length() > 0);
        assertTrue(atRoot("manual.pdf"));
    }

    @Test public void staleSelectionAndUndoCollisionsPreserveFiles() throws Exception {
        Uri notes = put("notes.txt", "first");
        JSONArray selection = ids(room().scan());
        write(notes, "different");
        try { room().tidy(selection); fail("Old selection should be refused"); }
        catch (IOException expected) { assertTrue(atRoot("notes.txt")); }
        room().tidy(ids(room().scan()));
        put("notes.txt", "new original");
        try { room().undo(); fail("Existing file must survive"); }
        catch (IOException expected) { assertTrue(atRoot("notes.txt")); }
        TreeStore.Entry shelf = store.directory("Room Reset - Documents", false);
        assertNotNull(store.named(shelf.id, "notes.txt"));
    }

    private static String javascript(Instrumentation test, RoomActivity activity, String source) throws Exception {
        ArrayBlockingQueue<String> result = new ArrayBlockingQueue<>(1);
        test.runOnMainSync(() -> {
            android.view.ViewGroup content = activity.findViewById(android.R.id.content);
            WebView web = (WebView) content.getChildAt(0);
            web.evaluateJavascript(source, result::offer);
        });
        String value = result.poll(45, TimeUnit.SECONDS);
        assertNotNull("WebView failed to reply", value);
        return value;
    }

    private static void waitFor(Instrumentation test, RoomActivity activity, String expression) throws Exception {
        long end = android.os.SystemClock.elapsedRealtime() + 90000;
        while (android.os.SystemClock.elapsedRealtime() < end) {
            if ("true".equals(javascript(test, activity, expression))) return;
            Thread.sleep(150);
        }
        fail("Room state did not meet " + expression + " | " + javascript(test, activity, "document.body.innerText"));
    }

    @Test public void gameSweepsSelectedFolderAndUndoesThroughWebBridge() throws Exception {
        put("game-test.pdf", "illustrated manual");
        SharedPreferences state = context.getSharedPreferences("room-state", Context.MODE_PRIVATE);
        String old = state.getString("tree", null);
        state.edit().putString("tree", tree.toString()).commit();
        Instrumentation test = InstrumentationRegistry.getInstrumentation();
        RoomActivity activity = launchRoom(test);
        try {
            waitFor(test, activity, "typeof window.roomReply === 'function' && document.querySelector('.backdrop').naturalWidth > 0");
            javascript(test, activity, "document.querySelector('#practice').click();document.querySelector('#folder').click()");
            waitFor(test, activity, "document.querySelector('#count').textContent === '1 to sort'");
            javascript(test, activity, "document.querySelector('#sweep').click()");
            waitFor(test, activity, "document.querySelector('#sheet').open");
            javascript(test, activity, "document.querySelector('#sheetActions .confirm').click()");
            waitFor(test, activity, "document.querySelector('#count').textContent === 'All tidy'");
            assertFalse(atRoot("game-test.pdf"));
            javascript(test, activity, "document.querySelector('#undo').click()");
            waitFor(test, activity, "document.querySelector('#count').textContent === '1 to sort'");
            assertTrue(atRoot("game-test.pdf"));
            javascript(test, activity, "document.querySelector('#practice').click()");
        } finally {
            test.runOnMainSync(activity::finish);
            state.edit().putString("tree", old).commit();
        }
    }
}
