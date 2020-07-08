local espejo = import 'lib/espejo.libsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local resourcelocker = import 'lib/resource-locker.libjsonnet';
local inv = kap.inventory();

local params = inv.parameters.networkpolicy;
local allowLabels = params.allowNamespaceLabels;

local labelNoDefaults = 'network-policies.syn.tools/no-defaults';
local labelPurgeDefaults = 'network-policies.syn.tools/purge-defaults';

local allowOthers = kube.NetworkPolicy('allow-from-other-namespaces') {
  spec+: {
    ingress+: [{
      from: [
        {
          namespaceSelector: {
            matchLabels: {
              [key]: labels[key]
              for key in std.objectFields(labels)
            },
          },
        }
        for labels in allowLabels
      ],
    }],
  },
};

local allowSameNamespace = kube.NetworkPolicy('allow-from-same-namespace') {
  spec+: {
    ingress: [{
      from: [{
        podSelector: {},
      }],
    }],
  },
};

local syncConfig = espejo.syncConfig('networkpolicies-default') {
  spec: {
    namespaceSelector: {
      labelSelector: {
        matchExpressions: [
          {
            key: labelNoDefaults,
            operator: 'DoesNotExist',
          },
        ],
      },
    },
    syncItems: [allowSameNamespace] +
               if std.length(allowLabels) > 0 then [allowOthers] else [],
  },
};

local purgeConfig = espejo.syncConfig('networkpolicies-purge-defaults') {
  spec: {
    namespaceSelector: {
      labelSelector: {
        [labelPurgeDefaults]: 'true',
      },
    },
    deleteItems: [{
      apiVersion: policy.apiVersion,
      kind: policy.kind,
      name: policy.metadata.name,
    } for policy in syncConfig.spec.syncItems],
  },
};

local labelPatches = std.flattenArrays([
  resourcelocker.Patch(kube.Namespace(ns), {
    metadata: {
      labels: {
        [labelNoDefaults]: 'true',
        [labelPurgeDefaults]: 'true',
      },
    },
  })
  for ns in params.ignoredNamespaces
]);


{
  [if std.length(labelPatches) > 0 then '00_label_patches']: labelPatches,
  [if std.length(params.ignoredNamespaces) > 0 then '05_purge_defaults']: purgeConfig,
  '10_default_networkpolicies': syncConfig,
}
