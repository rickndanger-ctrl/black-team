'use strict';
const {contextBridge,ipcRenderer}=require('electron');
const actions=new Set(['setup-help','installed-discover','hermes-inspect','phone-setup','phone-off','integrations-save','harness-connect','harness-launch','server-discover','status','setup-save','models-find','models-add','model-switch','model-forget','runtime-start','runtime-stop','phone-save','phone-detect','phone-command','phone-connect','phone-disconnect','open-data']);
contextBridge.exposeInMainWorld('blackTeam',Object.freeze({
  request(action,data={}){if(!actions.has(action))return Promise.reject(new Error('Unsupported desktop action.'));return ipcRenderer.invoke('black-team:request',action,data);},
  pick(kind){if(!['model','runtime','workspace','executable','hermes-source'].includes(kind))return Promise.reject(new Error('Unsupported chooser.'));return ipcRenderer.invoke('black-team:pick',kind);},
}));
