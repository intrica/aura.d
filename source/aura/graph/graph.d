﻿/**
	* Graph Storage Class
	*
	* Copyright: © 2015 David Monagle
	* License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	* Authors: David Monagle
*/
module aura.graph.graph;

import aura.graph.model;
import aura.graph.value;
import aura.graph.adapter;
import aura.graph.embedded;
import aura.graph.events;

import vibe.data.serialization;
import vibe.core.log;

import std.algorithm;
import std.array;
import std.traits;
import std.format;

/// Exposes a graph property
interface GraphInstanceInterface {
	@ignore @property inout(Graph) graph() inout;
	@property void graph(Graph value);
}


/// Defines a graph property to comply with `GraphInstanceInterface`
mixin template GraphInstanceImplementation() {
	@ignore @property inout(Graph) graph() inout { return _graph; }
	@property void graph(Graph value) { _graph = value; }
	
protected:
	Graph _graph;
}

/// Main storage class for Graph
class Graph : GraphEventListener {
	mixin GraphModelStoreImplementation;
	mixin GraphEventListenerImplementation;
	
	this() {
		registerGraphEventListener(this);
	}
	
	// As the graph is an event listener of itself, it needs to implement the GraphInstanceInterface 
	@ignore @property inout(Graph) graph() inout { return this; }
	@property void graph(Graph value) {}
	
	/// Injects a model into the graph, optionally initiating a snapshot
	/// If the model already exists in the graph, the original is returned unless replace is true
	/// A snapshot is only taken if the model does not already exist in the graph
	M inject(M : GraphModelInterface)(M model, bool snapshot = false, bool replace = false, string file = __FILE__, typeof(__LINE__) line = __LINE__) 
	in {
		assert(model, format("An attempt to inject a null %s into the graph was made %s(%s)", M.stringof, file, line));
		assert (model.graphType == M.stringof, "class " ~ M.stringof ~ "'s graphType does not match the classname: " ~ model.graphType);
	}
	body {
		bool addToStore = true;

		if (model.graph !is this) {
			if (model.graphPersisted && !replace) { // A model can only preexist if it has been persisted
				if (auto existing = firstModel!(M, (m) => m.graphId == model.graphId)(this)) {
					model = existing;
					addToStore = false; // Don't add to store as the existing one will be returned
				}
			}

			if (addToStore) {
				modelStore!(M).addModel(model);
				ensureGraphReferences(model);
				if (snapshot) model.takeSnapshot;
			}
		}

		return model;
	}
	
	/// Removes the given model from the graph, has no effect if the model is not part of the graph
	void remove(M : GraphModelInterface)(M model, string file = __FILE__, typeof(__LINE__) line = __LINE__)
	in {
		assert (model.graphType == M.stringof, "class " ~ M.stringof ~ "'s graphType does not match the classname: " ~ model.graphType);
		assert(model.graph is this, format("Called graph.remove on instance of %s but it's graph property did not match  %s(%s)", M.stringof, file, line));
	}
	body {
		modelStore!(M).removeModel(model);
	}
	
	/// Returns the default adapter for the graph
	@property GraphAdapterInterface defaultAdapter() { return _defaultAdapter; }
	/// Sets the default adapter for the graph
	@property void defaultAdapter(GraphAdapterInterface adapter) { 
		_defaultAdapter = adapter; 
		adapter.graph = this;
	}
	
	/// Ensures that `this` is set to be the graph on the model and all embedded models
	void ensureGraphReferences(M : GraphModelInterface)(M model) {
		model.graph = this;
		eachEmbeddedGraph!((model, parent) {
				model.graph = this;
				model.graphParent = parent;
			})(model);
	}

	size_t length() const {
		size_t result;
		foreach(store; _graphModelStores) result += store.length;
		return result;
	}
	
	/// Initiates a sync of the graph with the adapter
	bool sync() {
		if (!_defaultAdapter) return false;
		emitGraphWillSync;
		auto result =_defaultAdapter.sync;
		emitGraphDidSync;
		return result;
	}

	/// Clears all of the data stored in the graph whether it is persisted or not
	alias clear = clearModelStores;

	/// Clears all of the given model type
	void clear(M)() {
		clearModelStore!M;
	}

	/// Instantiates a listener of type `T` and registers it with this graph
	void registerGraphEventListener(T : GraphEventListener)() {
		registerGraphEventListener(new T());
	}


	/// Registers a listener with this graph
	void registerGraphEventListener(GraphEventListener listener) {
		if (!_graphEventListeners.canFind(listener)) {
			_graphEventListeners ~= listener;
			listener.graph = this;
		}
	}
	
	/// Unregisters the listener with this graph
	void unregisterGraphEventListener(GraphEventListener listener) {
		_graphEventListeners = array(_graphEventListeners.filter!((l) => listener !is l));
	}
	
	// Query methods

	/// Searches for a model with the matching key and value and returns it
	/// This will return the first model that matches. If no models match delegate function will be called.
	/// The first results will be injected int othe graph and returned. Otherwise null is returned
	M find(M, string key, V)(V value, M delegate() adapterSearch, bool snapshot = true) {
		auto graphResults = this.filterModels!(M, key)(value);
		if (graphResults.length) return graphResults[0];
		
		if (defaultAdapter) {
			auto adapterResult = adapterSearch();
			if (adapterResult) {
                return inject!M(adapterResult, snapshot);
            }
		}
		
		return null;
    }

	/// Searches for a model with the matching key and value and returns it
	/// This will return the first model that matches, if no models match, the defaultAdapter (if set) will be used to perform the search
	/// any result will be injected into the graph and returned. If no result is found, null is returned.
	/// This function is best used for keys that are considered "primary" in their collections.
	M find(M, string key, V : GraphValue)(V value, bool snapshot = true) {
        return find!(M, key, V)(value, () {
			auto results = defaultAdapter.graphFind(M.stringof, key, value, 1);
            if (results.length) return cast(M)results[0];
            return null;
        }, snapshot);
	}

	/// Ditto
	M find(M, string key, V)(V value) {
		return find!(M, key)(GraphValue(value));
	}

	/// Searches for models with the given key and value.
	/// Unlike the find method, the delegate function is always called, each match is checked to see if it already exists in the graph.
	/// If a model exists and replace is false, then the original model is returned, otherwise it is replaced in the graph with the
	/// version returned from the defaultAdapter.
	M[] findMany(M, string key, V : GraphValue)(V value, GraphModelInterface[] delegate() adapterSearch, uint limit = 0, bool snapshot = true, bool replace = false) {
        auto adapterResults = adapterSearch();
        foreach(result; adapterResults) {
            inject(cast(M)result, snapshot, replace); 
        }

		return filterModels!(M, key)(this, value);
	}

	/// Searches for models with the given key and value.
	/// Unlike the find method, the defaultAdapter, if set, is always consulted, each match is checked to see if it already exists in the graph.
	/// If a model exists and replace is false, then the original model is returned, otherwise it is replaced in the graph with the
	/// version returned from the defaultAdapter.
	/// If no defaultAdapter is set, this just returns all matching models already in the graph
	M[] findMany(M, string key, V : GraphValue)(V value, uint limit = 0, bool snapshot = true, bool replace = false) {
        return findMany!(M, key, V)(value, () {
            return defaultAdapter.graphFind(M.stringof, key, value, limit);            
        }, limit, snapshot, replace);
	}

	/// Ditto
	M[] findMany(M, string key, V)(V value, uint limit = 0, bool snapshot = true, bool replace = false) {
		return findMany!(M, key)(GraphValue(value));
	}


	// Emit methods
	void emitGraphWillSync() { foreach(listener; _graphEventListeners) listener.graphWillSync(); }
	void emitModelWillSave(GraphModelInterface model) { foreach(listener; _graphEventListeners) listener.modelWillSave(model); }
	void emitModelDidSave(GraphModelInterface model) { foreach(listener; _graphEventListeners) listener.modelDidSave(model); }
	void emitModelWillDelete(GraphModelInterface model) { foreach(listener; _graphEventListeners) listener.modelWillDelete(model); }
	void emitModelDidDelete(GraphModelInterface model) { foreach(listener; _graphEventListeners) listener.modelDidDelete(model); }
	void emitGraphDidSync() { foreach(listener; _graphEventListeners) listener.graphDidSync(); }
	
private:
	GraphAdapterInterface _defaultAdapter;
	GraphEventListener[] _graphEventListeners;
}

/// Returns the first model that matches the predicate. Else returns null
M firstModel(M : GraphModelInterface, alias predicate = (m) => true)(Graph graph) {
	auto result = graph.modelStore!M.find!((m) => predicate(cast(M)m));
	if (!result.length) return null;
	return cast(M)result.front;
}

/// Returns an array of M from within the graph that match the given predicate
M[] filterModels(M : GraphModelInterface, alias predicate = (m) => true)(Graph graph) {
	auto results = array(graph.modelStore!M.filter!((m) => predicate(cast(M)m)));
	return array(results.map!((m) => cast(M)m));
}

/*
/// Returns an array of M from within the graph that match the given predicate
M[] filterModels(M : GraphModelInterface)(Graph graph, bool delegate(M) predicate) {
	auto results = array(graph.modelStore!M.filter!((m) => predicate(cast(M)m)));
	return array(results.map!((m) => cast(M)m));
}
*/

/// Returns an array of M from within the graph where key matches value
M[] filterModels(M : GraphModelInterface, string key, V)(Graph graph, V value) {
	return graph.filterModels!(M, (model) => __traits(getMember, model, key) == value);
}


version (unittest) {
	class TestGraphModel : GraphModelInterface {
		mixin GraphModelImplementation;
		override @property string graphId() const { return id; }
		override @property void graphId(string newId) { id = newId; }

		string id;
	}
	
	class Animal : TestGraphModel {
		string name;
	}
	
	class Human : Animal {
		string title;
	}
	
	unittest {
		auto graph = new Graph();
		
		auto david = graph.inject(new Human());
		david.name = "David";
		david.title = "Mr";
		assert(graph.modelStore!Human.length == 1);
		
		auto ginny = graph.inject(new Human());
		ginny.name = "Ginny";
		ginny.title = "Mrs";
		assert(graph.modelStore!Human.length == 2);
		
		auto mia = graph.inject(new Animal());
		mia.name = "Mia";
		assert(graph.modelStore!Animal.length == 1);
		
		auto person = cast(Human)graph.modelStore!Human[0];
		assert(person.name == "David");
		
		assert(graph.filterModels!(Human, (m) => m.name == "David").length == 1);
	}
	
	// Test snapshots
	unittest {
		auto graph = new Graph();
		
		auto david = graph.inject(new Human(), true); // Inject and take snapshot
		david.name = "David";
		david.title = "Mr";
		assert(graph.modelStore!Human.length == 1);
		
		auto ginny = graph.inject(new Human()); // Default is no snapshot
		assert(ginny.graph);
		ginny.name = "Ginny";
		ginny.title = "Miss";
		assert(graph.modelStore!Human.length == 2);
		
		auto mia = graph.inject(new Animal());
		mia.name = "Mia";
		assert(graph.modelStore!Animal.length == 1);
		
		assert(david.graphHasSnapshot);
		
		assert(!ginny.graphHasSnapshot);
		ginny.takeSnapshot; // Take a snapshot
		ginny.title = "Mrs";
		assert(ginny.graphSnapshot["title"] == "Miss");
		auto oldGinny = ginny;
		ginny.revertToSnapshot;
		assert(ginny.title == "Miss");
		assert(oldGinny is ginny);
		
		assert(ginny.graph);
		graph.remove(ginny);
		assert(graph.modelStore!Human.length == 1);
	}
}
