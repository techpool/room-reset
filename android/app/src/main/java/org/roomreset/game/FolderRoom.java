package org.roomreset.game;

import android.content.Context;
import android.content.SharedPreferences;
import android.net.Uri;
import android.provider.DocumentsContract;
import android.provider.DocumentsContract.Document;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.*;
import org.json.JSONArray;
import org.json.JSONObject;

final class FolderRoom {
    private final TreeStore store;
    private final SharedPreferences prefs;
    private final String journalKey;
    private final JSONArray journal;
    private static String shelfName(String kind) {
        switch (kind) {
            case "paper": return "Room Reset - Documents";
            case "media": return "Room Reset - Media";
            case "archive": return "Room Reset - Archives";
            case "cache": return "Room Reset - Staged";
            default: throw new IllegalArgumentException("Unknown shelf.");
        }
    }

    private static Set<String> extensions(String... names) {
        return new HashSet<>(Arrays.asList(names));
    }
    private static final Set<String> PAPER = extensions("txt","pdf","rtf","md","doc","docx","odt","xls","xlsx","csv","tsv","ppt","pptx","epub","pages","numbers","key");
    private static final Set<String> MEDIA = extensions("jpg","jpeg","png","gif","webp","heic","heif","avif","tiff","mp4","mov","m4v","mkv","webm","mp3","m4a","aac","wav","flac");
    private static final Set<String> ARCHIVE = extensions("zip","tar","gz","bz2","xz","7z","rar","tgz");

    FolderRoom(Context context, Uri tree) throws Exception {
        store = new TreeStore(context.getContentResolver(), tree);
        prefs = context.getSharedPreferences("room-journal", Context.MODE_PRIVATE);
        journalKey = tree.toString();
        journal = new JSONArray(prefs.getString(journalKey, "[]"));
        reconcile();
    }

    private void save() throws IOException {
        if (!prefs.edit().putString(journalKey, journal.toString()).commit()) throw new IOException("Could not save the undo history.");
    }

    private static boolean mongo(String name) {
        return name.endsWith(".archive") || name.endsWith(".archive.gz") || name.endsWith(".bson") || name.endsWith(".bson.gz")
                || ((name.contains("mongo") || name.contains("dump"))
                    && (name.endsWith(".gz") || name.endsWith(".zip") || name.endsWith(".dump")));
    }

    private static final class Item {
        final TreeStore.Entry file;
        final String kind, token;
        final TreeStore.Entry keeper;
        Item(TreeStore.Entry file, String kind, TreeStore.Entry keeper, String tree) throws Exception {
            this.file = file;
            this.kind = kind;
            this.keeper = keeper;
            JSONArray parts = new JSONArray().put(tree).put(file.id).put(file.name).put(file.modified).put(file.size).put(kind);
            if (keeper != null) parts.put(keeper.id).put(keeper.modified);
            token = TreeStore.hex(MessageDigest.getInstance("SHA-256").digest(parts.toString().getBytes(StandardCharsets.UTF_8)));
        }
        JSONObject json() throws Exception {
            return new JSONObject().put("id", token).put("name", file.name).put("kind", kind).put("bytes", file.size);
        }
    }

    private static String plainName(String name) {
        int dot = name.lastIndexOf('.');
        if (dot < 1) return null;
        String stem = name.substring(0, dot);
        String plain = stem.replaceFirst("(?i)(?: \\([1-9][0-9]*\\)| copy(?: [1-9][0-9]*)?)$", "");
        return plain.equals(stem) ? null : plain + name.substring(dot);
    }

    private static int copyRank(String name) {
        String lower = name.toLowerCase(Locale.ROOT);
        if (lower.contains("copy") || lower.matches(".*\\([0-9]+\\).*")) return 1;
        return 0;
    }

    private Map<String, Item> inventory() throws Exception {
        List<TreeStore.Entry> files = store.children(store.root);
        files.sort(Comparator.comparingInt((TreeStore.Entry e) -> copyRank(e.name == null ? "" : e.name))
                .thenComparing(e -> e.name == null ? "" : e.name, String.CASE_INSENSITIVE_ORDER)
                .thenComparing(e -> e.id));
        Map<String, Item> result = new LinkedHashMap<>();
        Map<Long, List<TreeStore.Entry>> dumps = new LinkedHashMap<>();
        Map<String, Item> named = new HashMap<>();
        Map<String, String> hashes = new HashMap<>();
        for (TreeStore.Entry f : files) {
            if (!f.movableFile() || f.name.startsWith(".")) continue;
            String name = f.name.toLowerCase(Locale.ROOT);
            if (mongo(name)) {
                if (f.size > 0) dumps.computeIfAbsent(f.size, s -> new ArrayList<>()).add(f);
                continue;
            }
            int dot = name.lastIndexOf('.');
            if (dot <= 0) continue;
            String ext = name.substring(dot + 1);
            String kind = PAPER.contains(ext) ? "paper" : MEDIA.contains(ext) ? "media" : ARCHIVE.contains(ext) ? "archive" : null;
            if (kind != null) {
                Item item = new Item(f, kind, null, journalKey);
                result.put(item.token, item);
                named.put(f.name, item);
            }
        }
        Set<String> keep = new HashSet<>();
        for (Item copy : named.values()) {
            String plain = plainName(copy.file.name);
            if (plain == null || plainName(plain) != null) continue;
            Item keeper = named.get(plain);
            if (keeper == null || keeper.file.size != copy.file.size || (copy.file.flags & Document.FLAG_SUPPORTS_DELETE) == 0) continue;
            String keeperHash = hashes.get(keeper.file.id);
            if (keeperHash == null) {
                keeperHash = store.digest(keeper.file);
                hashes.put(keeper.file.id, keeperHash);
            }
            if (keeperHash.equals(store.digest(copy.file))) {
                result.remove(copy.token);
                keep.add(keeper.token);
                Item staged = new Item(copy.file, "cache", keeper.file, journalKey);
                result.put(staged.token, staged);
            }
        }
        // A keeper stays in place across launches, even after its duplicate has moved to staging.
        for (int i = 0; i < journal.length(); i++) {
            JSONObject e = journal.getJSONObject(i);
            if (!e.has("keeperId")) continue;
            Item protectedItem = named.get(e.getString("keeperName"));
            if (protectedItem != null && protectedItem.file.id.equals(e.getString("keeperId"))) keep.add(protectedItem.token);
        }
        keep.forEach(result::remove);
        for (List<TreeStore.Entry> group : dumps.values()) {
            if (group.size() < 2) continue;
            Map<String, TreeStore.Entry> keepers = new HashMap<>();
            for (TreeStore.Entry f : group) {
                String hash = store.digest(f);
                TreeStore.Entry keeper = keepers.putIfAbsent(hash, f);
                if (keeper == null || (f.flags & Document.FLAG_SUPPORTS_DELETE) == 0) continue;
                Item item = new Item(f, "cache", keeper, journalKey);
                result.put(item.token, item);
            }
        }
        return result;
    }

    JSONObject scan() throws Exception {
        JSONArray items = new JSONArray();
        for (Item item : inventory().values()) items.put(item.json());
        long bytes = 0;
        int count = 0;
        for (int i = 0; i < journal.length(); i++) {
            JSONObject entry = journal.getJSONObject(i);
            if ("cache".equals(entry.getString("kind"))) {
                TreeStore.Entry present = destination(entry);
                if (present != null && present.size == entry.getLong("size")) {
                    count++;
                    bytes += present.size;
                }
            }
        }
        return new JSONObject().put("name", store.detail(store.root).name).put("items", items)
                .put("canUndo", journal.length() > 0).put("stagedCount", count).put("stagedBytes", bytes);
    }

    // Only resolve direct children of the current organizer shelf inside the selected tree.
    private TreeStore.Entry destination(JSONObject e) throws Exception {
        TreeStore.Entry shelf = store.directory(shelfName(e.getString("kind")), false);
        if (shelf == null || !shelf.id.equals(e.getString("shelfId"))) return null;
        TreeStore.Entry file = store.named(shelf.id, e.getString("name"));
        if (file == null || file.directory() || !e.getString("name").equals(file.name)) return null;
        return e.has("to") && !file.id.equals(e.getString("to")) ? null : file;
    }

    private void reconcile() throws Exception {
        boolean changed = false;
        for (int i = journal.length() - 1; i >= 0; i--) {
            JSONObject entry = journal.getJSONObject(i);
            TreeStore.Entry dest = destination(entry);
            if (dest == null) {
                journal.remove(i);
                changed = true;
            } else if (!entry.has("to")) {
                // Interrupted between native move and journal commit. Ambiguous copies never become purgeable.
                if (store.named(store.root, entry.getString("name")) == null && verified(dest, entry)) {
                    entry.put("to", dest.id);
                } else {
                    journal.remove(i);
                }
                changed = true;
            }
        }
        if (changed) save();
    }

    private boolean verified(TreeStore.Entry file, JSONObject entry) throws Exception {
        return file != null && file.movableFile() && file.size == entry.getLong("size") && store.digest(file).equals(entry.getString("hash"));
    }

    JSONObject tidy(JSONArray ids) throws Exception {
        Map<String, Item> available = inventory();
        LinkedHashSet<Item> selected = new LinkedHashSet<>();
        for (int i = 0; i < ids.length(); i++) {
            Item item = available.get(ids.getString(i));
            if (item == null) throw new IOException("The folder changed. Scan it again.");
            selected.add(item);
        }
        String batch = UUID.randomUUID().toString();
        for (Item item : selected) {
            TreeStore.Entry shelf = store.directory(shelfName(item.kind), true);
            TreeStore.Entry source = store.named(store.root, item.file.name);
            if (source == null || !source.id.equals(item.file.id) || source.size != item.file.size
                    || source.modified != item.file.modified) throw new IOException("The file changed. Scan the folder again.");
            if (store.named(shelf.id, source.name) != null) throw new IOException("An item with this name already occupies the shelf.");
            String hash = store.digest(source);
            JSONObject entry = new JSONObject().put("kind", item.kind).put("batch", batch).put("shelfId", shelf.id)
                    .put("name", source.name).put("size", source.size).put("hash", hash);
            if (item.keeper != null) {
                entry.put("keeperId", item.keeper.id).put("keeperName", item.keeper.name);
                verifyKeeper(entry);
            }
            journal.put(entry);
            save();
            String movedId = store.move(source, store.root, shelf.id);
            entry.put("to", movedId);
            save();
        }
        return scan();
    }

    private TreeStore.Entry verifyKeeper(JSONObject e) throws Exception {
        TreeStore.Entry keeper = store.named(store.root, e.getString("keeperName"));
        if (keeper == null || !keeper.id.equals(e.getString("keeperId")) || !verified(keeper, e)) {
            throw new IOException("The original file changed or moved. The staged copy was kept.");
        }
        return keeper;
    }

    private static boolean samePurgeStamp(TreeStore.Entry checked, TreeStore.Entry current) {
        return current != null && checked.modified > 0 && checked.size >= 0 && current.movableFile()
                && checked.id.equals(current.id) && checked.name.equals(current.name)
                && checked.size == current.size && checked.modified == current.modified;
    }

    JSONObject undo() throws Exception {
        if (journal.length() == 0) return scan();
        String batch = journal.getJSONObject(journal.length()-1).getString("batch");
        for (int i = journal.length()-1; i >= 0; i--) {
            JSONObject e = journal.getJSONObject(i);
            if (!batch.equals(e.getString("batch"))) break;
            TreeStore.Entry file = destination(e);
            if (!verified(file, e)) throw new IOException("A sorted file changed. Both locations were left intact.");
            store.move(file, e.getString("shelfId"), store.root);
            journal.remove(i);
            save();
        }
        return scan();
    }

    JSONObject purge() throws Exception {
        for (int i = journal.length()-1; i >= 0; i--) {
            JSONObject e = journal.getJSONObject(i);
            if (!"cache".equals(e.getString("kind"))) continue;
            // A keeper may take minutes to read. Hash the staged copy last, then re-resolve both
            // names and compare the checked provider stamps immediately before removing it.
            TreeStore.Entry keeper = verifyKeeper(e);
            TreeStore.Entry file = destination(e);
            if (!verified(file, e)) throw new IOException("The staged file changed. It was kept.");
            TreeStore.Entry currentKeeper = store.named(store.root, e.getString("keeperName"));
            TreeStore.Entry currentFile = destination(e);
            if (!samePurgeStamp(keeper, currentKeeper) || !samePurgeStamp(file, currentFile)) {
                throw new IOException("The provider could not confirm both files are unchanged. The staged file was kept.");
            }
            if (!DocumentsContract.deleteDocument(store.resolver, store.uri(currentFile.id))) throw new IOException("Could not remove this staged copy.");
            journal.remove(i);
            save();
        }
        return scan();
    }
}
