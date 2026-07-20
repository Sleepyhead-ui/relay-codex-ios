const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("relayDesktop", {
  bootstrap: () => ipcRenderer.invoke("relay:bootstrap"),
  serviceStatus: () => ipcRenderer.invoke("relay:service-status"),
  startService: () => ipcRenderer.invoke("relay:start-service"),
  connect: (config) => ipcRenderer.invoke("relay:connect", config),
  disconnect: () => ipcRenderer.invoke("relay:disconnect"),
  send: (message) => ipcRenderer.invoke("relay:send", message),
  pickFiles: () => ipcRenderer.invoke("relay:pick-files"),
  showFile: (filePath) => ipcRenderer.invoke("relay:show-file", filePath),
  readImage: (filePath) => ipcRenderer.invoke("relay:read-image", filePath),
  onMessage: (listener) => {
    const handler = (_event, message) => listener(message);
    ipcRenderer.on("relay:message", handler);
    return () => ipcRenderer.removeListener("relay:message", handler);
  },
  onState: (listener) => {
    const handler = (_event, state) => listener(state);
    ipcRenderer.on("relay:state", handler);
    return () => ipcRenderer.removeListener("relay:state", handler);
  },
  onService: (listener) => {
    const handler = (_event, state) => listener(state);
    ipcRenderer.on("relay:service", handler);
    return () => ipcRenderer.removeListener("relay:service", handler);
  },
});
