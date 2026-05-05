import * as fs from 'fs';
import * as path from 'path';

/**
 * Absolute path to the directory containing SSM document YAML files.
 *
 * Consumers (vistral-cdk) should read from this path rather than guessing
 * the layout — that's the failure mode P1 #7 addresses (sibling-checkout
 * assumption breaking CI/CD that doesn't replicate the directory layout).
 */
export const documentsPath: string = path.resolve(__dirname, '..', 'documents');

/**
 * Returns absolute paths to every YAML SSM document in this package.
 * Throws if the documents directory is missing or empty — callers
 * (e.g. pre-deploy-check.sh) rely on this to fail fast.
 */
export function listDocuments(): string[] {
  if (!fs.existsSync(documentsPath)) {
    throw new Error(`vistral-ssm: documents directory not found at ${documentsPath}`);
  }
  const files = fs.readdirSync(documentsPath)
    .filter((f) => f.endsWith('.yaml') || f.endsWith('.yml'))
    .map((f) => path.join(documentsPath, f));
  if (files.length === 0) {
    throw new Error(`vistral-ssm: no document YAML files found in ${documentsPath}`);
  }
  return files;
}
