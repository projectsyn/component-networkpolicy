local espejo = import 'lib/espejo.libsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local inv = kap.inventory();

local params = inv.parameters.networkpolicy;
local allowLabels = params.allowNamespaceLabels;

local commonAnnotations = {
  'syn.tools/source': 'https://github.com/projectsyn/component-networkpolicy.git',
};

local commonItemLabels = {
  'app.kubernetes.io/managed-by': 'espejo',
  'app.kubernetes.io/part-of': 'syn',
  'app.kubernetes.io/component': 'networkpolicy',
};

local commonSyncLabels = {
  'app.kubernetes.io/part-of': 'syn',
  'app.kubernetes.io/component': 'networkpolicy',
};

local allowOthers = kube.NetworkPolicy('allow-from-other-namespaces') {
  metadata+: {
    annotations+: commonAnnotations,
    labels+: commonItemLabels,
  },
  spec+: {
    ingress+: [ {
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
    } ],
  },
};

local allowSameNamespace = kube.NetworkPolicy('allow-from-same-namespace') {
  metadata+: {
    annotations+: commonAnnotations,
    labels+: commonItemLabels,
  },
  spec+: {
    ingress: [ {
      from: [ {
        podSelector: {},
      } ],
    } ],
  },
};

local ciliumNetworkPlugins = [
  {
    apiVersion: 'cilium.io/v2',
    kind: 'CiliumNetworkPolicy',
    metadata: {
      name: 'allow-from-cluster-nodes',
    },
    spec: {
      endpointSelector: {},
      ingress: [
        {
          fromEntities: [
            'host',
            'remote-node',
          ],
        },
      ],
    },
  },
];

local syncConfig = espejo.syncConfig('networkpolicies-default') {
  metadata+: {
    annotations+: commonAnnotations,
    labels+: commonSyncLabels,
  },
  spec: {
    namespaceSelector: {
      ignoreNames: params.ignoredNamespaces,
      labelSelector: {
        matchExpressions: [
          {
            key: params.labels.noDefaults,
            operator: 'DoesNotExist',
          },
        ],
      },
    },
    syncItems: [ allowSameNamespace ] +
               (if std.asciiLower(params.networkPlugin) == 'cilium' then ciliumNetworkPlugins else []) +
               (if std.length(allowLabels) > 0 then [ allowOthers ] else []),
  },
};

local purgeConfig(name, namespaceSelector) = espejo.syncConfig(name) {
  metadata+: {
    annotations+: commonAnnotations,
    labels+: commonSyncLabels,
  },
  spec: {
    namespaceSelector: namespaceSelector,
    deleteItems: [ {
      apiVersion: policy.apiVersion,
      kind: policy.kind,
      name: policy.metadata.name,
    } for policy in syncConfig.spec.syncItems ],
  },
};


{
  '05_purge_defaults': [
    purgeConfig('networkpolicies-purge-defaults-ignored-namespaces', {
      matchNames: params.ignoredNamespaces,
    }),
    purgeConfig('networkpolicies-purge-defaults-by-label', {
      labelSelector: {
        matchLabels: {
          [params.labels.purgeDefaults]: 'true',
        },
      },
    }),
  ],
  '10_default_networkpolicies': syncConfig,
}
