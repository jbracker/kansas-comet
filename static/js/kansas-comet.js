// Kansas Comet jQuery plugin
(function($) {
   var the_prefix = "";
   var kansascomet_session;
   var eventQueues = {};   // TODO: add the use of the queue
   var eventCallbacks = {};

   $.kc = {
	connect: function(prefix) {
		the_prefix = prefix;
    		$.ajax({ url: the_prefix,
              		type: "POST",
              		data: "",
              		dataType: "script"});
	},
	session: function(session_id) {
		kansascomet_session = session_id;
		$.kc.redraw(0);
	},
	redraw: function (count) {
		$.ajax({ url: the_prefix + "/act/" + kansascomet_session + "/" + count,
            		type: "GET",
            		dataType: "script",
            		success: function success() { $.kc.redraw(count + 1); }
		       });
            	// TODO: Add failure; could happen
        },
	// This says someone is listening on a specific event
	// The full event name is "scope/eventname", for example
	// "body/click"
	register: function (scope, eventname, fn) {
		var fulleventname = scope + "/" + eventname;
     		eventQueues[fulleventname] = [];
     		$(scope).on(eventname, "." + eventname, function (event,aux) {
        		var e = fn(this,event,aux);
//			$("#log").append('{e:' + eventname  + '+' + $(this).slider('value') + ',' + $.toJSON(ui) + '}');
        		e.eventname = eventname;
			//      alert("EVENT " + e);
			$.kc.send(fulleventname,e);
     		});
	},

	send: function (fulleventname, event) {
		if (eventCallbacks[fulleventname] == undefined) {
                	eventQueues[fulleventname].push(event);
        	} else {
                	eventCallbacks[fulleventname](event);
        	}
	},
	
	// This waits for (full) named event(s). The second argument is the continuation
	waitFor: function (scope, eventnames, fn) {
		var prefixScope = function(o) { return scope + "/" + o; }
		for (eventname in eventnames) {
			var e = eventQueues[prefixScope(eventnames[eventname])].shift();
			if (e != undefined) {
				// call with event from queue
				fn(e);
				// and we are done
				return;	
			}
			if (eventCallbacks[prefixScope(eventnames[eventname])] != undefined) {
        			alert("ABORT: event queue callback failure for " + eventname);
			}
		}
		// All the callback better be undefined
		var f = function (e) {
          			// delete all the waiting callback(s)
				for (eventname in eventnames) {
					 delete eventCallbacks[prefixScope(eventnames[eventname])];
				}
          			// and do the callback
          			fn(e);
		};
		for (eventname in eventnames) {
			 eventCallbacks[prefixScope(eventnames[eventname])] = f;
		}
	},
	// There is a requirement that obj be an object or array.
	// See RFC 4627 for details.
	reply: function (uq,obj) {
        	$.ajax({ url: the_prefix + "/reply/" + kansascomet_session + "/" + uq,
                 	type: "POST",
                 	data: $.toJSON(obj),
                 	contentType: "application/json; charset=utf-8",
                 	dataType: "json"});
	}
     };
})(jQuery);





