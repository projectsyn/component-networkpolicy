local config = import 'config.json';

// Common annotations and labels
local commonAnnotations = {
  'syn.tools/source': 'https://github.com/projectsyn/component-networkpolicy.git',
};

local commonItemLabels = {
  'app.kubernetes.io/managed-by': 'espejote',
  'app.kubernetes.io/part-of': 'syn',
  'app.kubernetes.io/component': 'networkpolicy',
};

// Helper functions
local podSelector =
  if
    config.networkPlugin == 'cilium' && config.ciliumClusterID != ''
  then
    {
      matchLabels: {
        'io.cilium.k8s.policy.cluster': config.ciliumClusterID,
      },
    }
  else
    {};

local ciliumIngressPolicies = if std.length(config.allowFromNodeLabels) > 0 then [
  {
    // always allow access from local node's host network, e.g. health checks.
    fromEntities: [ 'host' ],
  },
  {
    fromNodes: [
      {
        matchLabels: config.allowFromNodeLabels,
      },
    ],
  },
] else [
  {
    fromEntities: [
      'host',
      'remote-node',
    ],
  },
];

// Actual NetworkPolicies
local allowFromOtherNamespaces = {
  apiVersion: 'networking.k8s.io/v1',
  kind: 'NetworkPolicy',
  metadata: {
    annotations: commonAnnotations,
    labels: commonItemLabels,
    name: 'allow-from-other-namespaces',
  },
};

local allowFromSameNamespace = {
  apiVersion: 'networking.k8s.io/v1',
  kind: 'NetworkPolicy',
  metadata: {
    annotations: commonAnnotations,
    labels: commonItemLabels,
    name: 'allow-from-same-namespace',
  },
};

local allowFromClusterNodes = {
  apiVersion: 'cilium.io/v2',
  kind: 'CiliumNetworkPolicy',
  metadata: {
    annotations: commonAnnotations,
    labels: commonItemLabels,
    name: 'allow-from-cluster-nodes',
  },
};

{
  // Export NetworkPolicy allow from other namespaces
  allowFromOtherNamespaces: allowFromOtherNamespaces,
  allowFromOtherWithSpec: allowFromOtherNamespaces {
    spec: {
      ingress: [ {
        from: [
          {
            namespaceSelector: {
              matchLabels: {
                [key]: labels[key]
                for key in std.objectFields(labels)
              },
            },
          }
          for labels in config.allowNamespaceLabels
        ],
      } ],
      // Hide unused optional egress field
      egress:: [],
    },
  },
  // Export NetworkPolicy allow from same namespace
  allowFromSameNamespace: allowFromSameNamespace,
  allowFromSameWithSpec: allowFromSameNamespace {
    spec: {
      ingress: [ {
        from: [ {
          podSelector: podSelector,
        } ],
      } ],
      // Hide unused optional egress field
      egress:: [],
    },
  },
  // Export CilliumNetworkPolicy allow from cluster nodes
  allowFromClusterNodes: allowFromClusterNodes,
  allowFromNodesWithSpec: allowFromClusterNodes {
    spec: {
      endpointSelector: {},
      ingress: ciliumIngressPolicies,
    },
  },
}
