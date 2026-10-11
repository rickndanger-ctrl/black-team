'use strict';
const {contextBridge,ipcRenderer}=require('electron');
const actions=new Set(['integrations-save','harness-launch','server-discover','status','setup-save','runtime-start','runtime-stop','phone-save','phone-detect','phone-command','phone-connect','phone-disconnect','open-data']);
contextBridge.exposeInMainWorld('blackTeam',Object.freeze({
  request(action,data={}){if(!actions.has(action))return Promise.reject(new Error('Unsupported desktop action.'));return ipcRenderer.invoke('black-team:request',action,data);},
  pick(kind){if(!['model','runtime','workspace'].includes(kind))return Promise.reject(new Error('Unsupported chooser.'));return ipcRenderer.invoke('black-team:pick',kind);},
}));
