# Windows: Open Files in Local Chat from Explorer

Flutter desktop apps are not registered in the Windows Share sheet the same way as Store apps. LocalChat supports a simpler command-line handoff instead:

```bat
local_chat.exe --share-file "C:\path\to\file.txt"
```

The app queues the file. Open a chat to stage and send it, matching the home-screen drag-and-drop flow.

## Context Menu Entry

Save the following as `local_chat_context.reg`, adjust the executable path, then double-click the file and confirm the registry merge.

```reg
Windows Registry Editor Version 5.00

[HKEY_CURRENT_USER\Software\Classes\*\shell\LocalChat]
@="Send with Local Chat"
"Icon"="C:\\Apps\\local_chat\\local_chat.exe,0"

[HKEY_CURRENT_USER\Software\Classes\*\shell\LocalChat\command]
@="\"C:\\Apps\\local_chat\\local_chat.exe\" --share-file \"%1\""
```

After merging, right-click a file in File Explorer and choose **Send with Local Chat**.

## Notes

- This is a per-user registry entry and does not require administrator access.
- On Windows 11, the entry may appear under **Show more options**.
- Multiple files can be sent by invoking the app once per file, or by dragging several files onto the LocalChat home window.
