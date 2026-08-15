// SJON VS Code extension entry. Starts an LSP client speaking stdio to the
// sjon-lsp server, and restarts it when the setting or a sjon-project.sjon
// changes. All server capabilities (diagnostics, hover, goto-def, semantic
// tokens, formatting) come from the server; this file only wires transport.
//
// `start` assumes no workspace: the server handles a project-less file fine,
// and the file watcher below simply matches nothing when there are no
// folders. That is what lets `onLanguage:sjon` activation be safe.

import * as vscode from 'vscode';
import {
  LanguageClient,
  type LanguageClientOptions,
  type ServerOptions,
  TransportKind,
} from 'vscode-languageclient/node';
import { lookupOnPath, resolveServerPath } from './serverPath.ts';

let client: LanguageClient | undefined;

function configuredPath(): string {
  return vscode.workspace.getConfiguration('sjon').get<string>('lsp.path', '');
}

async function start(context: vscode.ExtensionContext): Promise<void> {
  const server = resolveServerPath(configuredPath(), lookupOnPath);
  if (server === null) {
    void vscode.window.showErrorMessage(
      'SJON: could not find the `sjon-lsp` server. Build it with `zig build lsp`, then set `sjon.lsp.path` or put it on your PATH.',
    );
    return;
  }

  const serverOptions: ServerOptions = {
    run: { command: server, transport: TransportKind.stdio },
    debug: { command: server, transport: TransportKind.stdio },
  };
  const clientOptions: LanguageClientOptions = {
    documentSelector: [{ scheme: 'file', language: 'sjon' }],
    synchronize: {
      fileEvents: vscode.workspace.createFileSystemWatcher('**/sjon-project.sjon'),
    },
  };

  client = new LanguageClient('sjon', 'SJON Language Server', serverOptions, clientOptions);
  context.subscriptions.push(client);
  await client.start();
}

async function restart(context: vscode.ExtensionContext): Promise<void> {
  if (client !== undefined) {
    await client.stop();
    client = undefined;
  }
  await start(context);
}

export function activate(context: vscode.ExtensionContext): void {
  void start(context);
  context.subscriptions.push(
    vscode.workspace.onDidChangeConfiguration((e) => {
      if (e.affectsConfiguration('sjon.lsp.path')) {
        void restart(context);
      }
    }),
  );
}

export function deactivate(): Thenable<void> | undefined {
  return client?.stop();
}
