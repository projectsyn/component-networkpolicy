// main template for networkpolicy
local espejo = import 'lib/espejo.libsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local inv = kap.inventory();

local params = inv.parameters.networkpolicy;
local allowLabels = params.allowNamespaceLabels;

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
            key: 'espejo.syn.tools/no-network-policies',
            operator: 'DoesNotExist',
          },
        ],
      },
    },
    syncItems: [allowSameNamespace] +
               if std.length(allowLabels) > 0 then [allowOthers] else [],
  },
};

local pruneConfig = espejo.syncConfig('networkpolicies-prune-ignored') {
  spec: {
    namespaceSelector: {
      matchNames: params.ignoredNamespaces,
    },
    deleteItems: [
      {
        apiVersion: 'networking.k8s.io/v1',
        kind: 'NetworkPolicy',
        name: name,

      }
      for name in ['allow-from-other-namespaces', 'allow-from-same-namespace']
    ],
  },
};


// Define outputs below
{
  [if std.length(params.ignoredNamespaces) > 0 then '05_prune']: pruneConfig,
  '10_networkpolicies': syncConfig,
}
