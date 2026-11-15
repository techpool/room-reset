package org.roomreset.game;

import android.content.ContentResolver;
import android.database.Cursor;
import android.net.Uri;
import android.provider.DocumentsContract;
import android.provider.DocumentsContract.Document;
import java.io.IOException;
import java.io.InputStream;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.List;

final class TreeStore {
    final ContentResolver resolver;
    final Uri tree;
    final String root;
    static final String[] COLUMNS = { Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME,
            Document.COLUMN_MIME_TYPE, Document.COLUMN_SIZE, Document.COLUMN_LAST_MODIFIED, Document.COLUMN_FLAGS };

    TreeStore(ContentResolver resolver, Uri tree) {
        this.resolver = resolver;
        this.tree = tree;
        this.root = DocumentsContract.getTreeDocumentId(tree);
    }

    static final class Entry {
        final String id, name, mime;
        final long size, modified;
        final int flags;
        Entry(Cursor row) {
            id = row.getString(0);
            name = row.getString(1);
            mime = row.getString(2);
            size = row.isNull(3) ? -1 : row.getLong(3);
            modified = row.getLong(4);
            flags = row.getInt(5);
        }
        boolean directory() { return Document.MIME_TYPE_DIR.equals(mime); }
        boolean movableFile() {
            return !directory() && name != null && id != null && size >= 0
                    && (flags & Document.FLAG_VIRTUAL_DOCUMENT) == 0 && (flags & Document.FLAG_SUPPORTS_MOVE) != 0;
        }
    }

    Uri uri(String id) { return DocumentsContract.buildDocumentUriUsingTree(tree, id); }

    List<Entry> children(String dir) throws IOException {
        Uri list = DocumentsContract.buildChildDocumentsUriUsingTree(tree, dir);
        ArrayList<Entry> result = new ArrayList<>();
        try (Cursor c = resolver.query(list, COLUMNS, null, null, null)) {
            if (c == null) throw new IOException("This folder is unavailable.");
            if (c.getExtras().getBoolean(DocumentsContract.EXTRA_LOADING)
                    || c.getExtras().containsKey(DocumentsContract.EXTRA_ERROR)) {
                throw new IOException("This folder is still loading. Try again.");
            }
            while (c.moveToNext()) result.add(new Entry(c));
        }
        return result;
    }

    Entry detail(String id) throws IOException {
        try (Cursor c = resolver.query(uri(id), COLUMNS, null, null, null)) {
            if (c == null || !c.moveToFirst()) throw new java.io.FileNotFoundException("This file or folder has moved.");
            return new Entry(c);
        }
    }

    Entry named(String dir, String name) throws IOException {
        Entry result = null;
        for (Entry e : children(dir)) {
            if (!name.equalsIgnoreCase(e.name)) continue;
            if (result != null) throw new IOException("Several entries have the same name.");
            result = e;
        }
        return result;
    }

    Entry directory(String name, boolean create) throws IOException {
        Entry e = named(root, name);
        if (e == null && create) {
            Uri made = DocumentsContract.createDocument(resolver, uri(root), Document.MIME_TYPE_DIR, name);
            if (made == null) throw new IOException("Could not create the organizer folder.");
            e = detail(DocumentsContract.getDocumentId(made));
        }
        if (e != null && (!e.directory() || !name.equals(e.name))) {
            throw new IOException("An entry already uses the organizer folder name.");
        }
        return e;
    }

    String move(Entry e, String oldDir, String newDir) throws IOException {
        if (named(newDir, e.name) != null) throw new IOException("A file with this name already exists. Both files were kept.");
        Uri moved = DocumentsContract.moveDocument(resolver, uri(e.id), uri(oldDir), uri(newDir));
        if (moved == null) throw new IOException("This folder provider could not move the file.");
        return DocumentsContract.getDocumentId(moved);
    }

    String digest(Entry file) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        byte[] block = new byte[128 * 1024];
        long size = 0;
        try (InputStream input = resolver.openInputStream(uri(file.id))) {
            if (input == null) throw new IOException("Could not read this file.");
            int n;
            while ((n = input.read(block)) != -1) {
                digest.update(block, 0, n);
                size += n;
            }
        }
        Entry after = detail(file.id);
        if (size != file.size || after.size != file.size || after.modified != file.modified || !file.name.equals(after.name)) {
            throw new IOException("The file changed while Room Reset was checking it.");
        }
        return hex(digest.digest());
    }

    static String hex(byte[] bytes) {
        StringBuilder out = new StringBuilder(bytes.length * 2);
        for (byte b : bytes) out.append(Character.forDigit((b & 255) >>> 4, 16)).append(Character.forDigit(b & 15, 16));
        return out.toString();
    }
}
