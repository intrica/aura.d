﻿module aura.graph.relationships;

import aura.graph;
import transforms;
import inflections.en;

string defineGraphBelongsToProperty(M, string propertyName, string key, string foreignKey)() {
	import std.string;
	
	static if (!propertyName.length) 
		immutable string _propertyName = M.stringof.camelCaseLower;
	else
		immutable string _propertyName = propertyName;
	
	static if (!key.length)
		immutable string _key = _propertyName ~ "Id";
	else
		immutable string _key = key;
	
	return format(`
		@ignore @property %1$s %2$s(string file = __FILE__, typeof(__LINE__) line = __LINE__) {
			enforce(graph, "Attempted to use GraphBelongsTo property '%2$s(%1$s)' on model '" ~ graphType ~ "' without a graph instance", file, line);
			return graph.find!(%1$s, "%3$s")(%4$s);
		}
	`, M.stringof, _propertyName, foreignKey, _key);
}

mixin template GraphBelongsTo(M, string propertyName = "", string key = "", string foreignKey = "_id") {
	mixin(defineGraphBelongsToProperty!(M, propertyName, key, foreignKey));
}

string defineGraphOuterBelongsTo(L, M, string propertyName, string key, string foreignKey)() {
	import std.string;
	
	static if (!propertyName.length) 
		string _propertyName = M.stringof.camelCaseLower;
	else
		string _propertyName = propertyName;
	
	static if (!key.length)
		string _key = _propertyName ~ "Id";
	else
		string _key = key;
	
	return format(`
		%1$s %2$s(%5$s model) {
			assert(model.graph, "Attempted to use BelongsTo property '%2$s' on model '%1$s' without a graph");
			%1$s returnValue;
			if (model.graph) returnValue = model.graph.find!(%1$s,"%4$s")(model.%3$s);
			return returnValue;
		}
	`, M.stringof, _propertyName, _key, foreignKey, L.stringof);
}

mixin template GraphBelongsTo(L, M, string propertyName = "", string key = "", string foreignKey = "_id") {
	mixin(defineGraphOuterBelongsTo!(L, M, propertyName, key, foreignKey));
}

/*
interface GraphRelationship {
	bool resolved() const;
	void resolve(bool force);
}

class GraphBelongsTo(M : GraphModelInterface) : GraphRelationship {
	this() {
	}

	this(M relation) {
		_relation = relation;
	}

	bool resolved() const { return _relation ? true : false; }
	void resolve(bool force) {}
	
	@property M relation() {
		return _relation;
	}
	
	void opAssign(M model) { _relation = model; }
	
	alias relation this;
	
private:
	M _relation;
}

version (unittest) {
	class GraphTestUser : GraphModelInterface {
		mixin GraphModelImplementation;
		
		string id;
		string name;

		override @property string graphId() const { return id; }
		override @property void graphId(string newId) { id = newId; }
	}
	
	unittest {
		GraphBelongsTo!GraphTestUser belongsTo;
		belongsTo = new GraphBelongsTo!GraphTestUser;
		assert(!belongsTo.resolved);

		auto user = new GraphTestUser;
		user.name = "David";

		belongsTo = user;

		assert(belongsTo.resolved);
		assert(belongsTo.name == "David");
	}
	
}
*/
