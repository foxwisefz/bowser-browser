import { Store } from './store.js';
import { backup } from 'node:sqlite';
import { chmodSync, existsSync } from 'node:fs';

// Local operator access only. Email is unverified; never authorize these
// operations solely from someone supplying an email or registration ID online.
process.umask(0o077);
const [operation, argument] = process.argv.slice(2);
const allowed = ['prune-events', 'withdraw-training', 'delete-registration', 'backup'];
if (!process.env.BOWSER_DATABASE || !allowed.includes(operation) || (operation !== 'prune-events' && !argument)) {
  console.error('Usage: BOWSER_DATABASE=/path node src/admin.js prune-events|withdraw-training ID|delete-registration ID|backup /new/path');
  process.exit(2);
}
const store = new Store(process.env.BOWSER_DATABASE);
try {
  if (operation === 'backup') {
    if (existsSync(argument)) throw new Error('Backup destination must not exist');
    await backup(store.db, argument); chmodSync(argument, 0o600); console.log('Backup complete');
  } else {
    const changed = operation === 'prune-events' ? store.prune(Date.now())
      : operation === 'withdraw-training' ? store.withdrawTraining(argument, Date.now()) : store.deleteRegistration(argument);
    console.log(`${changed} record(s) changed`);
  }
} finally { store.close(); }
