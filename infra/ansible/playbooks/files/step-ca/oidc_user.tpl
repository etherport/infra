{
	"type": {{ toJson .Type }},
	"keyId": {{ toJson .KeyID }},
	"principals": {{ toJson (concat .Principals (list "ubuntu" "root")) }},
	"extensions": {
		"permit-X11-forwarding": "",
		"permit-agent-forwarding": "",
		"permit-port-forwarding": "",
		"permit-pty": "",
		"permit-user-rc": ""
	},
	"criticalOptions": {{ toJson .CriticalOptions }}
}
