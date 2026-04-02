# Windows: open files in Local Chat from Explorer

Flutter desktop apps are not registered in the system **Share** sheet the same way as Store apps. You can still send a file path into Local Chat using a **“Send to Local Chat”** context-menu entry.

## Steps

1. Build or install Local Chat and note the full path to `local_chat.exe` (for example `C:\Apps\local_chat\local_chat.exe`).
2. Open Notepad, paste the template below, replace `FULL_PATH_TO_EXE` with your real path (keep the quotes).
3. Save as `local_chat_sendto.reg`, double-click it, and confirm the merge.
4. In File Explorer, right-click a file → **Show more options** (Windows 11) → **Send to** → **Local Chat** (if you used the SendTo folder method), **or** use the **context menu** method below.

### Context menu (per user, no admin)

Save as `local_chat_context.reg` (adjust the exe path):

```reg
Windows Registry Editor Version 5.00

[HKEY_CURRENT_USER\Software\Classes\*\shell\LocalChat]
@="Send with Local Chat"
"Icon"="C:\\Apps\\local_chat\\local_chat.exe,0"

[HKEY_CURRENT_USER\Software\Classes\*\shell\LocalChat\command]
@="\"C:\\Apps\\local_chat\\local_chat.exe\" --share-file \"%1\""
```

After merging, right-click a file → **Send with Local Chat**. The app queues the file; open a chat to attach it (same flow as drag-and-drop on the home screen).

**Multiple files:** run the app once per file, or drag several files onto the home window.
