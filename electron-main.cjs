const { app, BrowserWindow, screen } = require('electron');
const path = require('path');

let mainWindow;

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
        frame: false, // No app borders or close buttons
        alwaysOnTop: true, // Keep it above other apps
        hasShadow: false, // No windows dropshadow
        skipTaskbar: true, // Don't show in alt-tab or taskbar (optional, good for floating mascots)
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

    app.on('activate', () => {
        if (BrowserWindow.getAllWindows().length === 0) createWindow();
    });
});

app.on('window-all-closed', () => {
    if (process.platform !== 'darwin') app.quit();
});
