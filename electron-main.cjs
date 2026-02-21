const { app, BrowserWindow, screen, Tray, Menu } = require('electron');
const path = require('path');

let mainWindow;
let tray = null;

function createWindow() {
    const primaryDisplay = screen.getPrimaryDisplay();
    const { width, height } = primaryDisplay.workAreaSize;

    // Set the window to be a small square floating at the bottom right
    const winWidth = 400;
    const winHeight = 500;

    mainWindow = new BrowserWindow({
        width: winWidth,
        height: winHeight,
        x: width - winWidth - 20, // 20px from right edge
        y: height - winHeight - 20, // 20px from bottom edge
        transparent: true, // Transparent background!
        backgroundColor: '#00000000', // actually fully transparent
        frame: false, // No app borders or close buttons
        alwaysOnTop: true, // Keep it above other apps
        hasShadow: false, // No windows dropshadow
        skipTaskbar: true, // hide from Alt-Tab and main taskbar
        webPreferences: {
            nodeIntegration: true,
            contextIsolation: false
        }
    });

    // Make it so the user can click *through* the transparent parts of the window? 
    // For a tamagotchi, we might want to interact with it, so we leave clicks enabled for now.
    // mainWindow.setIgnoreMouseEvents(true, { forward: true });

    // Load the Vite Dev Server (React app)
    mainWindow.loadURL('http://localhost:3000');

    // mainWindow.webContents.openDevTools({ mode: 'detach' }); // Un-comment to debug
}

app.whenReady().then(() => {
    createWindow();

    // -- Adding System Tray Icon --
    // We create a simple empty icon or native icon for the "Hidden Icons" area
    const { nativeImage } = require('electron');
    const emptyIcon = nativeImage.createEmpty();
    tray = new Tray(emptyIcon);
    const contextMenu = Menu.buildFromTemplate([
        { label: 'FocusPals 3D Mascot', type: 'normal', enabled: false },
        { type: 'separator' },
        { label: 'Quit', click: () => { app.quit(); } }
    ]);
    tray.setToolTip('FocusPals Tama 3D');
    tray.setContextMenu(contextMenu);

    app.on('activate', () => {
        if (BrowserWindow.getAllWindows().length === 0) createWindow();
    });
});

app.on('window-all-closed', () => {
    if (process.platform !== 'darwin') app.quit();
});
