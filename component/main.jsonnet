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
               if std.length(allowLabels) > 0 then [ allowOthers ] else [],
  },
};

local purgeConfigLabel = espejo.syncConfig('networkpolicies-purge-defaults-by-label') {
  metadata+: {
    annotations+: commonAnnotations,
    labels+: commonSyncLabels,
  },
  spec: {
    namespaceSelector: {
      labelSelector: {
        matchLabels: {
          [params.labels.purgeDefaults]: 'true',
        },
      },
    },
    deleteItems: [ {
      apiVersion: policy.apiVersion,
      kind: policy.kind,
      name: policy.metadata.name,
    } for policy in syncConfig.spec.syncItems ],
  },
};

local purgeConfigIgnoredNamespaces = espejo.syncConfig('networkpolicies-purge-defaults-ignored-namespaces') {
  metadata+: {
    annotations+: commonAnnotations,
    labels+: commonSyncLabels,
  },
  spec: {
    namespaceSelector: {
      matchNames: params.ignoredNamespaces,
    },
    deleteItems: [ {
      apiVersion: policy.apiVersion,
      kind: policy.kind,
      name: policy.metadata.name,
    } for policy in syncConfig.spec.syncItems ],
  },
};

{
  '05_purge_defaults': [ purgeConfigIgnoredNamespaces, purgeConfigLabel ],
  '10_default_networkpolicies': syncConfig,
}
